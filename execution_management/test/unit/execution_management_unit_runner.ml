let () =
  Alcotest.run "trading-execution-management-unit"
    [
      ("kill_switch", Kill_switch_test.tests);
      ("rate_limit", Rate_limit_test.tests);
      ("open_order_ticket_process", Open_order_ticket_process_test.tests);
      ("immediate", Immediate_test.tests);
      ("twap", Twap_test.tests);
      ("vwap", Vwap_test.tests);
      ("pov", Pov_test.tests);
      ("iceberg", Iceberg_test.tests);
      ("implementation_shortfall", Implementation_shortfall_test.tests);
      ("order_ticket", Order_ticket_test.tests);
    ]
