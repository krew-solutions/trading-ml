(** Unit test runner for Portfolio Management BC. Mirrors {!portfolio_management/lib/}. *)

let () =
  Alcotest.run "trading-portfolio-management-unit"
    [
      ("target_portfolio", Target_portfolio_test.tests);
      ("actual_portfolio", Actual_portfolio_test.tests);
      ("reconciliation", Reconciliation_test.tests);
      ("risk_policy", Risk_policy_test.tests);
      ("pair_mean_reversion", Pair_mean_reversion_test.tests);
      ("alpha_view", Alpha_view_test.tests);
    ]
