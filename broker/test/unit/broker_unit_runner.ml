(** Unit test runner for Broker BC. Covers the ACL adapters (Finam,
    BCS), the BCS refresh-token store, the WebSocket framing layer,
    and the outbound integration-event DTOs. *)

let () =
  Alcotest.run "trading-broker-unit"
    [
      (* ACL: Finam *)
      ("finam dto", Finam_dto_test.tests);
      ("finam auth", Finam_auth_test.tests);
      ("finam ws proto", Finam_ws_test.tests);
      ("finam orders", Finam_order_test.tests);
      (* ACL: Finam gRPC *)
      ("finam-grpc conv", Finam_grpc_conv_test.tests);
      (* ACL: BCS *)
      ("bcs auth", Bcs_auth_test.tests);
      ("bcs rest", Bcs_rest_test.tests);
      ("bcs ws", Bcs_ws_test.tests);
      ("bcs orders", Bcs_order_test.tests);
      ("bcs deals", Bcs_deals_test.tests);
      (* ACL: Alor *)
      ("alor dto", Alor_dto_test.tests);
      ("alor auth", Alor_auth_test.tests);
      ("alor rest", Alor_rest_test.tests);
      ("alor ws", Alor_ws_test.tests);
      (* Infrastructure: secret storage (BCS refresh-token) *)
      ("token store", Token_store_test.tests);
      (* Infrastructure: WebSocket framing *)
      ("ws frame", Websocket_frame_test.tests);
      (* Application: integration events *)
      ("bar_updated DTO", Bar_updated_integration_event_test.tests);
      (* Application: commands *)
      ("cancel_pending_order workflow", Cancel_pending_order_command_workflow_test.tests);
      ("watch_public_trades command", Watch_public_trades_command_test.tests);
    ]
