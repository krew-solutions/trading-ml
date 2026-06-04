(** gRPC channel over HTTP/2 + TLS, Eio-native.

    One {!t} owns a single multiplexed HTTP/2 connection to the Finam gRPC
    endpoint (TLS, ALPN ["h2"]). gRPC streams (unary calls and server-streams
    alike) are multiplexed over it, per the gRPC-over-HTTP/2 wire protocol.

    The transport is built on [grpc] core (message framing + status decoding),
    [h2] / {!Eio_gluten} (the HTTP/2 state machine driven over a {!Tls_eio}
    flow), and [tls-eio] / [x509] for the secure channel. We deliberately do not
    depend on [grpc-eio]: see {!Eio_gluten} for why.

    Errors surface as the {!Grpc_error} exception, mirroring how the REST sibling
    raises on non-2xx — call sites stay value-oriented. *)

open Eio.Std

exception Grpc_error of { code : Grpc.Status.code; message : string option; rpc : string }

let () =
  Printexc.register_printer (function
    | Grpc_error { code; message; rpc } ->
        Some
          (Printf.sprintf "Finam gRPC %s: %s%s" rpc (Grpc.Status.show_code code)
             (match message with
             | Some m -> " (" ^ m ^ ")"
             | None -> ""))
    | _ -> None)

type t = {
  conn : H2.Client_connection.t;
  runtime : Eio_gluten.Client.t;
  authority : string;  (** host[:port] for the HTTP/2 [:authority] pseudo-header *)
}

(* ---- TLS authenticator ------------------------------------------------- *)

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let now () = Ptime.of_float_s (Unix.gettimeofday ())

(** Trust anchors from the OS CA bundle. Same candidate list as the REST
    sibling, so both transports validate against one source of truth. *)
let load_authenticator () =
  let candidates =
    [
      "/etc/ssl/certs/ca-certificates.crt";
      "/etc/pki/tls/certs/ca-bundle.crt";
      "/etc/ssl/cert.pem";
    ]
  in
  match List.find_opt Sys.file_exists candidates with
  | None -> Error "no CA bundle found in standard locations"
  | Some path -> (
      let pem = read_file path in
      match X509.Certificate.decode_pem_multiple pem with
      | Error (`Msg m) -> Error ("CA decode failed: " ^ m)
      | Ok certs -> Ok (X509.Authenticator.chain_of_trust ~time:now certs))

(* ---- connection -------------------------------------------------------- *)

let host_of_string host =
  match Domain_name.of_string host with
  | Ok d -> (
      match Domain_name.host d with
      | Ok h -> Some h
      | Error _ -> None)
  | Error _ -> None

(** Establish TCP → TLS (ALPN h2) → HTTP/2 client connection to [host:port].
    Runs under [sw]; the connection lives until the switch ends or it is
    {!shutdown}. *)
let connect ~sw ~env ~host ~port : t =
  let net = Eio.Stdenv.net env in
  let addr =
    match Eio.Net.getaddrinfo_stream net host ~service:(string_of_int port) with
    | [] -> failwith (Printf.sprintf "finam-grpc: cannot resolve %s" host)
    | a :: _ -> a
  in
  let raw = Eio.Net.connect ~sw net addr in
  let authenticator =
    match load_authenticator () with
    | Ok a -> a
    | Error m -> failwith ("finam-grpc TLS init: " ^ m)
  in
  let tls_cfg =
    match Tls.Config.client ~authenticator ~alpn_protocols:[ "h2" ] () with
    | Ok c -> c
    | Error (`Msg m) -> failwith ("finam-grpc TLS config: " ^ m)
  in
  let flow =
    (Tls_eio.client_of_flow ?host:(host_of_string host) tls_cfg raw
      :> Eio.Flow.two_way_ty Eio.Resource.t)
  in
  let conn = H2.Client_connection.create ~error_handler:(fun _ -> ()) () in
  let runtime =
    Eio_gluten.Client.create ~sw ~read_buffer_size:H2.Config.default.read_buffer_size
      ~protocol:(module H2.Client_connection)
      conn flow
  in
  { conn; runtime; authority = Printf.sprintf "%s:%d" host port }

let shutdown t = Eio.Promise.await (Eio_gluten.Client.shutdown t.runtime)
let is_closed t = Eio_gluten.Client.is_closed t.runtime

(* ---- gRPC call machinery ---------------------------------------------- *)

let base_headers t ~metadata =
  H2.Headers.of_list
    ([
       (":authority", t.authority);
       ("te", "trailers");
       ("content-type", "application/grpc+proto");
     ]
    @ metadata)

(** Status promise + a trailers handler that resolves it from a
    [grpc-status] / [grpc-message] header set. Idempotent: the first resolution
    wins (trailers, or a trailers-only HEADERS frame, whichever lands first). *)
let make_status_waiter () =
  let status, resolve = Promise.create () in
  let handle (headers : H2.Headers.t) =
    match H2.Headers.get headers "grpc-status" with
    | None -> ()
    | Some s -> (
        match Option.bind (int_of_string_opt s) Grpc.Status.code_of_int with
        | Some code when not (Promise.is_resolved status) ->
            (* grpc-message is percent-encoded on the wire (gRPC spec). *)
            let message =
              Option.map Uri.pct_decode (H2.Headers.get headers "grpc-message")
            in
            Promise.resolve resolve (Grpc.Status.v ?message code)
        | _ -> ())
  in
  (status, handle)

(** Drain framed gRPC messages from [body], invoking [on_message] per complete
    message and [on_eof] once the body ends. Framing per {!Grpc.Message}. *)
let recv_messages body ~on_message ~on_eof =
  let buffer = Grpc.Buffer.v () in
  let rec on_read bs ~off ~len =
    Grpc.Buffer.copy_from_bigstringaf ~src_off:off ~src:bs ~dst:buffer ~length:len;
    Grpc.Message.extract_all on_message buffer;
    H2.Body.Reader.schedule_read body ~on_eof ~on_read
  in
  H2.Body.Reader.schedule_read body ~on_eof ~on_read

(** Open one stream, send [request] (a single already-encoded protobuf message),
    then run [recv] over the response body. [recv read_body] {b must block} until
    the response body is fully consumed (EOF); the trailing [grpc-status] is
    parsed by then. Returns the resolved gRPC status. Raises {!Grpc_error} on a
    non-OK HTTP/2 response status. *)
let call t ~rpc ~metadata ~request ~recv : Grpc.Status.t =
  (* [rpc] is the gRPC [:path]. The generated RPC modules expose it (with a
     leading slash) as [.name]; tolerate a slash-less form too. *)
  let path = if String.length rpc > 0 && rpc.[0] = '/' then rpc else "/" ^ rpc in
  let req =
    H2.Request.create ~scheme:"https" ~headers:(base_headers t ~metadata) `POST path
  in
  let response, resolve_response = Promise.create () in
  let read_body, resolve_read_body = Promise.create () in
  let status, trailers_handler = make_status_waiter () in
  let response_handler (resp : H2.Response.t) (body : H2.Body.Reader.t) =
    Promise.resolve resolve_response resp;
    Promise.resolve resolve_read_body body
  in
  let write_body =
    H2.Client_connection.request t.conn ~flush_headers_immediately:true ~trailers_handler
      req
      ~error_handler:(fun _ -> ())
      ~response_handler
  in
  H2.Body.Writer.write_string write_body (Grpc.Message.make request);
  H2.Body.Writer.close write_body;
  let resp = Promise.await response in
  let body = Promise.await read_body in
  match resp.status with
  | `OK ->
      (* Resolve status eagerly from headers too: a trailers-only response
         carries grpc-status in the HEADERS frame, not in trailers. *)
      trailers_handler resp.headers;
      recv body;
      if Promise.is_resolved status then Promise.await status
      else Grpc.Status.v ~message:"server did not return grpc-status" Grpc.Status.Unknown
  | other ->
      raise
        (Grpc_error
           {
             code = Grpc.Status.Unknown;
             message = Some (Format.asprintf "HTTP/2 %a" H2.Status.pp_hum other);
             rpc;
           })

let raise_if_error ~rpc (status : Grpc.Status.t) =
  match Grpc.Status.code status with
  | Grpc.Status.OK -> ()
  | code -> raise (Grpc_error { code; message = Grpc.Status.message status; rpc })

(** Unary RPC. [request]/result are raw encoded protobuf message bytes.
    Raises {!Grpc_error} unless the final status is OK; raises on a missing
    response message. *)
let unary t ~rpc ~metadata ~request : string =
  let result = ref None in
  let status =
    call t ~rpc ~metadata ~request ~recv:(fun body ->
        let done_p, resolve_done = Promise.create () in
        recv_messages body
          ~on_message:(fun msg -> if !result = None then result := Some msg)
          ~on_eof:(fun () ->
            if not (Promise.is_resolved done_p) then Promise.resolve resolve_done ());
        Promise.await done_p)
  in
  raise_if_error ~rpc status;
  match !result with
  | Some msg -> msg
  | None ->
      raise
        (Grpc_error
           { code = Grpc.Status.Unknown; message = Some "no response message"; rpc })

(** Server-streaming RPC. Sends one [request], invokes [on_message] for each
    response message until the server half-closes, then returns. Raises
    {!Grpc_error} if the final status is not OK. Blocks the calling fiber for the
    lifetime of the stream. *)
let server_streaming t ~rpc ~metadata ~request ~on_message : unit =
  let status =
    call t ~rpc ~metadata ~request ~recv:(fun body ->
        let done_p, resolve_done = Promise.create () in
        recv_messages body ~on_message ~on_eof:(fun () ->
            if not (Promise.is_resolved done_p) then Promise.resolve resolve_done ());
        Promise.await done_p)
  in
  raise_if_error ~rpc status
