(** Component test runner for Execution_management BC. *)

let () =
  Alcotest.run "trading-execution-management-component"
    [
      Order_process_manager_saga_test.feature;
      Order_ticket_cancel_test.feature;
    ]
