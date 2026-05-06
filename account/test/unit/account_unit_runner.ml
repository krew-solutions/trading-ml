(** Unit test runner for Account BC. Mirrors {!account/lib/}. *)

let () = Alcotest.run "trading-account-unit" [ ("portfolio", Portfolio_test.tests) ]
