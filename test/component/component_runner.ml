(** Component tests — touch multiple layers in one process, substituting
    network/IO with loopback or fakes. Slower than unit, faster than
    e2e. Example: the WebSocket echo roundtrip uses in-process TCP,
    a server-side handshake helper, and the real [Ws_client] stack. *)

let () = Alcotest.run "trading-component" [ ("ws echo", Ws_echo_test.tests) ]
