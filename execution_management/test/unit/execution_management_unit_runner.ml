let () =
  Alcotest.run "trading-execution-management-unit"
    [
      ("kill_switch", Kill_switch_test.tests);
      ("rate_limit", Rate_limit_test.tests);
      ("order_process_manager", Order_process_manager_test.tests);
      ("immediate", Immediate_test.tests);
      ("twap", Twap_test.tests);
      ("vwap", Vwap_test.tests);
      ("pov", Pov_test.tests);
      ("iceberg", Iceberg_test.tests);
      ("implementation_shortfall", Implementation_shortfall_test.tests);
      ("order_ticket", Order_ticket_test.tests);
      ( "order_ticket_view_model",
        Order_ticket_view_model_test.tests );
      ( "order_ticket_integration_events",
        Order_ticket_opened_integration_event_test.tests );
      ("queries", Queries_test.tests);
      ("execution_directive_parse", Execution_directive_parse_test.tests);
    ]
