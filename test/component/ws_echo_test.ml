(** Integration test for [Finam.Ws_client] against a local in-process
    echo server. Verifies the full pipeline: TCP connect, HTTP Upgrade
    handshake, text frame send, text frame recv, close. *)

let tcp_pair ~sw env =
  let net = Eio.Stdenv.net env in
  let loopback = Eio.Net.Ipaddr.V4.loopback in
  let listener =
    Eio.Net.listen ~reuse_addr:true ~backlog:1 ~sw net
      (`Tcp (loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr listener with
    | `Tcp (_, p) -> p | _ -> assert false
  in
  listener, port

let test_echo_roundtrip () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let listener, port = tcp_pair ~sw env in
  (* Server fiber: accept one connection and echo until close. *)
  let server_done = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    Eio.Net.accept_fork ~sw listener
      ~on_error:(fun _ -> ())
      (fun flow _addr ->
         Ws_server_test_helper.accept_and_echo flow;
         Eio.Promise.resolve (snd server_done) ()));
  (* Client fiber: connect and roundtrip. *)
  let uri = Uri.of_string
    (Printf.sprintf "ws://127.0.0.1:%d/echo" port) in
  let client = Finam.Ws_client.connect ~env ~sw ~uri () in
  Finam.Ws_client.send_text client "hello";
  (match Finam.Ws_client.recv client with
   | Text "hello" -> ()
   | Text other -> Alcotest.failf "echoed: %s" other
   | _ -> Alcotest.fail "non-text reply");
  Finam.Ws_client.send_text client "and again";
  (match Finam.Ws_client.recv client with
   | Text "and again" -> ()
   | _ -> Alcotest.fail "second echo");
  Finam.Ws_client.send_close client ()

let tests = [
  "echo text roundtrip", `Quick, test_echo_roundtrip;
]
