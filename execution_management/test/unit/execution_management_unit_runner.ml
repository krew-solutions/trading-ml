let () =
  Alcotest.run "trading-execution-management-unit"
    [
      ("immediate", Immediate_test.tests);
      ("twap", Twap_test.tests);
      ("vwap", Vwap_test.tests);
      ("pov", Pov_test.tests);
      ("iceberg", Iceberg_test.tests);
      ("implementation_shortfall", Implementation_shortfall_test.tests);
      ("order_ticket", Order_ticket_test.tests);
      ("order_ticket_view_model", Order_ticket_view_model_test.tests);
      ("order_ticket_integration_events", Order_ticket_opened_integration_event_test.tests);
      ("queries", Queries_test.tests);
      ("execution_directive_parse", Execution_directive_parse_test.tests);
      ("broker_volume_feed", Broker_volume_feed_test.tests);
      ("broker_market_data", Broker_market_data_test.tests);
      ("bar_updated_handler", Bar_updated_handler_test.tests);
    ]
