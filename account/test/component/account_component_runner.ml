(** Component test runner for Account BC. *)

let () = Alcotest.run "trading-account-component" [ Reserve_command_test.feature ]
