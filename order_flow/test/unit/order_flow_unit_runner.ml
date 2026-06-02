(** Unit test runner for the Order_flow BC. Mirrors {!order_flow/lib/}. *)

let () =
  Alcotest.run "trading-order_flow-unit"
    [
      ("footprint", Footprint_test.tests);
      ("footprint_history", Footprint_history_test.tests);
      ("bar_boundary token codec", Bar_boundary_token_test.tests);
    ]
