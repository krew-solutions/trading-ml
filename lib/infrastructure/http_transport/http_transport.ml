(** Broker-agnostic HTTP transport layer.
    Gives each broker integration a small [request -> response]
    function that hides Eio, TLS and cohttp behind it. Having a single
    implementation avoids drift between [Finam] and [Bcs] TLS
    configurations (CA loading, domain name validation, etc.). *)

(** Request shape — intentionally tiny. Complex features (multipart,
    streaming bodies) live in the caller, not here. *)
type headers = (string * string) list

type request = {
  meth : [ `GET | `POST | `PUT | `DELETE ];
  url : Uri.t;
  headers : headers;
  body : string option;
}

type response = {
  status : int;
  body : string;
}

type t = request -> response

let fake (responder : request -> response) : t = responder

(** Wrap a broker-specific "send with auth" pattern around a transport.
    [build_request token] must produce a [request] with an
    [Authorization: Bearer …] header using [token]. On 401 we
    [invalidate ()], then ask [get_token ()] again (which must refresh
    under the hood) and retry exactly once. Covers the race where the
    server invalidates a JWT slightly before our local cache expected. *)
let with_auth_retry
    ~(get_token : unit -> string)
    ~(invalidate : unit -> unit)
    ~(build_request : token:string -> request)
    (transport : t) : response =
  let token = get_token () in
  let resp = transport (build_request ~token) in
  if resp.status = 401 then begin
    invalidate ();
    let token' = get_token () in
    transport (build_request ~token:token')
  end else resp

(** --- Eio-backed implementation --- *)

let read_file path =
  In_channel.with_open_bin path In_channel.input_all

let now () =
  match Ptime.of_float_s (Unix.gettimeofday ()) with
  | Some t -> Some t
  | None -> Some Ptime.epoch

let load_authenticator () =
  let candidates = [
    "/etc/ssl/certs/ca-certificates.crt";   (* Debian/Ubuntu *)
    "/etc/pki/tls/certs/ca-bundle.crt";     (* Fedora/RHEL *)
    "/etc/ssl/cert.pem";                    (* macOS/OpenBSD *)
  ] in
  match List.find_opt Sys.file_exists candidates with
  | None -> Error "no CA bundle found in standard locations"
  | Some path ->
    let pem = read_file path in
    match X509.Certificate.decode_pem_multiple pem with
    | Error (`Msg m) -> Error ("CA decode failed: " ^ m)
    | Ok certs -> Ok (X509.Authenticator.chain_of_trust ~time:now certs)

(** Per-request deadline. Without a cap a stalled remote or a
    half-open TCP session silently freezes the caller; 15 s is long
    enough for fat payloads like [/v1/accounts/…/orders] over a slow
    uplink, short enough that smoke tests fail rather than hang a
    session.

    Covers both connect and response-read; [Eio.Time.with_timeout]
    cancels the switch and all its flow reads when the budget runs
    out. *)
let request_timeout_s = 15.0

let make_eio ~env : t =
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let authenticator =
    match load_authenticator () with
    | Ok a -> a
    | Error m -> failwith ("TLS init failed: " ^ m)
  in
  let tls_config =
    match Tls.Config.client ~authenticator () with
    | Ok c -> c
    | Error (`Msg m) -> failwith ("TLS config failed: " ^ m)
  in
  let https =
    let connect uri raw =
      let host =
        match Uri.host uri with
        | Some h ->
          (match Domain_name.of_string h with
           | Ok d ->
             (match Domain_name.host d with
              | Ok h -> Some h | Error _ -> None)
           | Error _ -> None)
        | None -> None
      in
      Tls_eio.client_of_flow ?host tls_config raw
    in
    Some connect
  in
  let client = Cohttp_eio.Client.make ~https net in
  let send_once (req : request) : response =
    match
      Eio.Time.with_timeout clock request_timeout_s @@ fun () ->
      Eio.Switch.run @@ fun sw ->
      let headers = Cohttp.Header.of_list req.headers in
      let body = Option.map Cohttp_eio.Body.of_string req.body in
      let resp, body_in =
        match req.meth with
        | `GET    -> Cohttp_eio.Client.get    ~sw ~headers client req.url
        | `DELETE -> Cohttp_eio.Client.delete ~sw ~headers client req.url
        | `POST   ->
          Cohttp_eio.Client.post ~sw ~headers ?body client req.url
        | `PUT    ->
          Cohttp_eio.Client.put ~sw ~headers ?body client req.url
      in
      let status = Cohttp.Code.code_of_status (Cohttp.Response.status resp) in
      let body_str = Eio.Flow.read_all body_in in
      Ok { status; body = body_str }
    with
    | Ok r -> r
    | Error `Timeout ->
      failwith (Printf.sprintf
        "HTTP timeout after %.0fs on %s %s"
        request_timeout_s
        (match req.meth with
         | `GET -> "GET" | `POST -> "POST"
         | `PUT -> "PUT" | `DELETE -> "DELETE")
        (Uri.to_string req.url))
  in
  (* Cohttp's client keeps a pool of TCP+TLS connections for keepalive.
     Brokers (notably BCS) close idle pooled connections after a few
     seconds; the next request through that stale entry surfaces
     either as [End_of_file] (clean FIN) or as [Eio.Io Net
     Connection_reset] (abortive RST). Retry once on those — a fresh
     pool entry skips the dead connection.

     Retry applies to every method, including POST / PUT. The safety
     argument rests on idempotency keys:
       - GET / DELETE: idempotent by HTTP semantics.
       - Auth POSTs ([/token], [/v1/sessions]): issuing another JWT
         for the same secret is safe; also retried locally in the
         [Auth] modules, this is a belt-and-braces backup.
       - Order-writing POSTs carry a [clientOrderId] (UUID):
         [Bcs.Rest.create_order]/[cancel_order]/[edit_order] and
         [Finam.Rest.place_order] all pass one. Both brokers dedupe
         by it — a retry with the same cid either lands once or
         returns the existing order; it never creates a duplicate.
     If a future caller adds a mutating POST without an idempotency
     key, it must either tolerate the retry or switch to a non-
     retrying path. *)
  let is_stale_keepalive : exn -> bool = function
    | End_of_file -> true
    | Eio.Io (Eio.Net.E (Connection_reset _), _) -> true
    | _ -> false
  in
  fun (req : request) : response ->
    try send_once req
    with e when is_stale_keepalive e -> send_once req
