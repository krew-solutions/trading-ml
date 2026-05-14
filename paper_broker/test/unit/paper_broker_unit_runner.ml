let () =
  Alcotest.run "trading-paper-broker-unit"
    [
      ("slippage", Slippage_test.tests);
      ("fee", Fee_test.tests);
      ("matching", Matching_test.tests);
      ("order", Order_test.tests);
    ]
