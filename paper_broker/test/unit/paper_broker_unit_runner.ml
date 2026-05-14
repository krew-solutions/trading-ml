let () =
  Alcotest.run "trading-paper-broker-unit"
    [
      ("slippage", Slippage_test.tests);
      ("fee", Fee_test.tests);
      ("matching", Matching_test.tests);
      ("order", Order_test.tests);
      ("submit_order_command_workflow", Submit_order_command_workflow_test.tests);
      ("apply_bar_command_workflow", Apply_bar_command_workflow_test.tests);
      ( "cancel_pending_order_command_workflow",
        Cancel_pending_order_command_workflow_test.tests );
    ]
