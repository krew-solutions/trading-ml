(** Component test runner for the order_flow BC. *)

let () = Alcotest.run "trading-order_flow-component" [ Ingest_print_command_test.feature ]
