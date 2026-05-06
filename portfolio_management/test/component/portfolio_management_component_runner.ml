(** Component test runner for Portfolio Management BC. *)

let () =
  Alcotest.run "trading-portfolio-management-component"
    [
      Set_target_command_test.feature;
      Reconcile_command_test.feature;
      Projection_test.feature;
      Pair_mr_pipeline_test.feature;
      Define_alpha_view_command_test.feature;
    ]
