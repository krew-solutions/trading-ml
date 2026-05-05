(** Unit test runner for shared kernel. Mirrors {!shared/lib/}. *)

let () =
  Alcotest.run "trading-shared-unit"
    [
      ("bus", Bus_test.tests);
      ("in_memory", In_memory_test.tests);
      ("decimal", Decimal_test.tests);
      ("rop", Rop_test.tests);
      ("workflow_engine", Workflow_engine_test.tests);
      (* Domain core *)
      ("mic", Mic_test.tests);
      ("ticker", Ticker_test.tests);
      ("isin", Isin_test.tests);
      ("board", Board_test.tests);
      ("instrument", Instrument_test.tests);
    ]
