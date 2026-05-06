(** Unit test runner for Broker BC. Mirrors {!lib/broker/}; covers
    ACL adapters (Finam, BCS) for now — paper decorator and any
    new application-layer tests will land in this same runner. *)

let () =
  Alcotest.run "trading-broker-unit"
    [
      (* ACL: Finam *)
      ("finam dto", Finam_dto_test.tests);
      ("finam auth", Finam_auth_test.tests);
      ("finam ws proto", Finam_ws_test.tests);
      ("finam orders", Finam_order_test.tests);
      (* ACL: BCS *)
      ("bcs auth", Bcs_auth_test.tests);
      ("bcs rest", Bcs_rest_test.tests);
      ("bcs ws", Bcs_ws_test.tests);
      ("bcs orders", Bcs_order_test.tests);
      ("bcs deals", Bcs_deals_test.tests);
      (* Infrastructure: Paper decorator *)
      ("paper broker", Paper_broker_test.tests);
      (* Infrastructure: secret storage (BCS refresh-token) *)
      ("token store", Token_store_test.tests);
      (* Infrastructure: WebSocket framing *)
      ("ws frame", Websocket_frame_test.tests);
      (* Application: integration events *)
      ("bar_updated DTO", Bar_updated_integration_event_test.tests);
    ]
