(** Eio + cohttp-eio + TLS implementation of [Transport.t].
    Loads the system CA bundle once at construction time so each request
    can reuse the same authenticator. Falls back gracefully (raises with
    a clear error) when CA loading fails. *)

let read_file path =
  In_channel.with_open_bin path In_channel.input_all

let now () =
  match Ptime.of_float_s (Unix.gettimeofday ()) with
  | Some t -> Some t
  | None -> Some Ptime.epoch

let load_authenticator () =
  let candidates = [
    "/etc/ssl/certs/ca-certificates.crt";   (* Debian, Ubuntu *)
    "/etc/pki/tls/certs/ca-bundle.crt";     (* Fedora, RHEL *)
    "/etc/ssl/cert.pem";                    (* macOS, OpenBSD *)
  ] in
  match List.find_opt Sys.file_exists candidates with
  | None -> Error "no CA bundle found in standard locations"
  | Some path ->
    let pem = read_file path in
    match X509.Certificate.decode_pem_multiple pem with
    | Error (`Msg m) -> Error ("CA decode failed: " ^ m)
    | Ok certs ->
      Ok (X509.Authenticator.chain_of_trust ~time:now certs)

let make ~env : Transport.t =
  let net = Eio.Stdenv.net env in
  let authenticator =
    match load_authenticator () with
    | Ok a -> a
    | Error m -> failwith ("Finam TLS init failed: " ^ m)
  in
  let tls_config =
    match Tls.Config.client ~authenticator () with
    | Ok c -> c
    | Error (`Msg m) -> failwith ("Finam TLS config failed: " ^ m)
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
  fun (req : Transport.request) : Transport.response ->
    Eio.Switch.run @@ fun sw ->
    let headers = Cohttp.Header.of_list req.headers in
    let body = Option.map Cohttp_eio.Body.of_string req.body in
    let resp, body_in =
      match req.meth with
      | `GET    -> Cohttp_eio.Client.get    ~sw ~headers client req.url
      | `DELETE -> Cohttp_eio.Client.delete ~sw ~headers client req.url
      | `POST   ->
        Cohttp_eio.Client.post ~sw ~headers ?body client req.url
    in
    let status = Cohttp.Code.code_of_status (Cohttp.Response.status resp) in
    let body_str = Eio.Flow.read_all body_in in
    { Transport.status; body = body_str }
