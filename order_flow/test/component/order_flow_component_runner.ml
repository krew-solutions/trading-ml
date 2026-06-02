(** Component test runner for the order_flow BC. *)

let () =
  Alcotest.run "trading-order_flow-component"
    [
      Ingest_print_command_test.feature;
      Trade_printed_handler_test.feature;
      Watch_footprints_command_test.feature;
      ("Volume bar (ingest workflow)", Ingest_print_volume_bar_test.tests);
    ]
