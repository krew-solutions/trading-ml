(** Unit test runner for pre_trade_risk. *)

let () =
  Alcotest.run "trading-pre-trade-risk-unit"
    [
      ("risk_limits", Risk_limits_test.tests);
      ("risk_view", Risk_view_test.tests);
      ("assessment", Assessment_test.tests);
    ]
