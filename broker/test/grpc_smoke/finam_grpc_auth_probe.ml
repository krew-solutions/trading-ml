(** Live connectivity smoke for the Finam gRPC transport.

    Exercises the whole stack end-to-end — TCP → TLS (ALPN h2) → HTTP/2 →
    gRPC framing → protobuf codec — by calling [AuthService.Auth] on
    [api.finam.ru:443].

    With [FINAM_SECRET] set it performs a real authentication and prints the
    JWT length. Without it, it sends a bogus secret and expects a {e structured
    gRPC status} back: receiving any well-formed gRPC status (rather than a TLS
    or HTTP/2 failure) already proves the transport is correct. Not part of
    [@runtest]: requires network reach. *)

module A = Finam_grpc_proto.Auth_service.Grpc.Tradeapi.V1.Auth

let pf fmt = Printf.ksprintf (fun s -> print_endline s) fmt

let () =
  Eio_main.run @@ fun env ->
  Mirage_crypto_rng_unix.use_default ();
  Eio.Switch.run @@ fun sw ->
  let secret =
    match Sys.getenv_opt "FINAM_SECRET" with
    | Some s ->
        pf "[info] FINAM_SECRET present — attempting real authentication";
        s
    | None ->
        pf
          "[info] FINAM_SECRET absent — sending a bogus secret; a structured gRPC status \
           still proves the transport";
        "BOGUS-SECRET-FOR-TRANSPORT-PROBE"
  in
  let ch = Finam_grpc.Channel.connect ~sw ~env ~host:"api.finam.ru" ~port:443 in
  pf "[ok] TLS+HTTP/2 connection established to api.finam.ru:443";
  let rpc =
    Printf.sprintf "%s.%s/%s"
      (Option.value ~default:"" A.AuthService.Auth.package_name)
      A.AuthService.Auth.service_name A.AuthService.Auth.method_name
  in
  pf "[info] calling %s" rpc;
  let encode, decode =
    Ocaml_protoc_plugin.Service.make_client_functions A.AuthService.auth
  in
  let request =
    A.AuthRequest.make ~secret () |> encode |> Ocaml_protoc_plugin.Writer.contents
  in
  (match Finam_grpc.Channel.unary ch ~rpc ~metadata:[] ~request with
  | bytes -> (
      match decode (Ocaml_protoc_plugin.Reader.create bytes) with
      | Ok token -> pf "[ok] Auth returned a JWT (length %d)" (String.length token)
      | Error e ->
          pf "[fail] response decode error: %s" (Ocaml_protoc_plugin.Result.show_error e))
  | exception Finam_grpc.Channel.Grpc_error { code; message; _ } ->
      pf "[ok] structured gRPC status: %s%s — transport works"
        (Grpc.Status.show_code code)
        (match message with
        | Some m -> " (" ^ m ^ ")"
        | None -> ""));
  Finam_grpc.Channel.shutdown ch
