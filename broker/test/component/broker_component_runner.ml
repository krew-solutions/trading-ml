(** Component tests for Broker BC — touch multiple layers in one
    process, substituting network/IO with loopback or fakes. Slower
    than unit, faster than e2e. Example: the WebSocket echo roundtrip
    uses in-process TCP, a server-side handshake helper, and the real
    [Websocket.Client] stack. *)

let () = Alcotest.run "trading-broker-component" [ ("ws echo", Ws_echo_test.tests) ]
