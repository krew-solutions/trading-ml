(** Unit test runner for Portfolio Management BC. Mirrors {!portfolio_management/lib/}. *)

let () =
  Alcotest.run "trading-portfolio-management-unit"
    [
      ("target_portfolio", Target_portfolio_test.tests);
      ("actual_portfolio", Actual_portfolio_test.tests);
      ("reconciliation", Reconciliation_test.tests);
      ("risk_policy", Risk_policy_test.tests);
      ("pair_mean_reversion", Pair_mean_reversion_test.tests);
      ("kalman_dlm_state", Kalman_dlm_state_test.tests);
      ("pair_kalman_mean_reversion", Pair_kalman_mean_reversion_test.tests);
      ("alpha_view", Alpha_view_test.tests);
      ("construction_intent", Construction_intent_test.tests);
      ("vol_state", Vol_state_test.tests);
      ("equity_proportional", Equity_proportional_test.tests);
      ("volatility_target", Volatility_target_test.tests);
      ("risk_config", Risk_config_test.tests);
      ( "build_target_on_construction_intent",
        Build_target_on_construction_intent_test.tests );
      ("configure_risk_command_handler", Configure_risk_command_handler_test.tests);
      ( "subscribe_book_to_alpha_command_handler",
        Subscribe_book_to_alpha_command_handler_test.tests );
      ("define_pair_mr_command_handler", Define_pair_mr_command_handler_test.tests);
      ( "define_pair_kalman_mr_command_handler",
        Define_pair_kalman_mr_command_handler_test.tests );
    ]
