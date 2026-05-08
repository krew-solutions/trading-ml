let () =
  Alcotest.run "trading-execution-management-unit"
    [
      ("kill_switch", Kill_switch_test.tests);
      ("rate_limit", Rate_limit_test.tests);
      ("place_order_pm", Place_order_pm_test.tests);
    ]
