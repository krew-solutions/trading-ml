(** Component test runner for paper_broker BC. *)

let () =
  Alcotest.run "trading-paper-broker-component" [ Paper_broker_pipeline_test.feature ]
