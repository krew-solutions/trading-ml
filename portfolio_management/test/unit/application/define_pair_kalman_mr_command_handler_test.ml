(** Unit tests for {!Define_pair_kalman_mr_command_handler}. *)

module Pm = Portfolio_management
module DPKM = Portfolio_management_commands.Define_pair_kalman_mr_command
module H = Portfolio_management_commands.Define_pair_kalman_mr_command_handler

let well_formed_cmd
    ?(book = "book-α")
    ?(a = "SBER@MISX")
    ?(b = "GAZP@MISX")
    ?(discount = "0.99")
    ?(v = "0.0001")
    ?(z_entry = "2.0")
    ?(z_exit = "0.5")
    ?(burn_in = 50)
    ?(prior_alpha = "0.0")
    ?(prior_beta = "1.0")
    ?(prior_variance = "1.0")
    () : DPKM.t =
  {
    book_id = book;
    a;
    b;
    discount;
    v;
    z_entry;
    z_exit;
    burn_in;
    prior_alpha;
    prior_beta;
    prior_variance;
  }

let make_registry () =
  let tbl :
      ( Pm.Common.Book_id.t * Pm.Common.Pair.t,
        Pm.Pair_kalman_mean_reversion.state )
      Hashtbl.t =
    Hashtbl.create 4
  in
  let persist ~book_id ~pair ~state = Hashtbl.replace tbl (book_id, pair) state in
  (tbl, persist)

let expect_validation_failure cmd =
  let _, persist = make_registry () in
  match H.handle ~persist_pair_kalman_mr_state:persist cmd with
  | Error _ -> ()
  | Ok () -> Alcotest.fail "expected Error"

let test_happy_path_persists () =
  let tbl, persist = make_registry () in
  match H.handle ~persist_pair_kalman_mr_state:persist (well_formed_cmd ()) with
  | Ok () -> Alcotest.(check int) "one entry" 1 (Hashtbl.length tbl)
  | Error _ -> Alcotest.fail "expected Ok"

let test_replaces_existing () =
  let tbl, persist = make_registry () in
  let _ =
    H.handle ~persist_pair_kalman_mr_state:persist (well_formed_cmd ~burn_in:50 ())
  in
  let _ =
    H.handle ~persist_pair_kalman_mr_state:persist (well_formed_cmd ~burn_in:80 ())
  in
  Alcotest.(check int) "still one entry (replaced)" 1 (Hashtbl.length tbl)

let test_rejects_same_legs () =
  expect_validation_failure (well_formed_cmd ~a:"SBER@MISX" ~b:"SBER@MISX" ())

let test_rejects_discount_at_zero () =
  expect_validation_failure (well_formed_cmd ~discount:"0" ())

let test_rejects_discount_at_one () =
  expect_validation_failure (well_formed_cmd ~discount:"1.0" ())

let test_rejects_discount_above_one () =
  expect_validation_failure (well_formed_cmd ~discount:"1.5" ())

let test_rejects_negative_v () =
  expect_validation_failure (well_formed_cmd ~v:"-0.001" ())

let test_rejects_zero_v () = expect_validation_failure (well_formed_cmd ~v:"0" ())

let test_rejects_negative_burn_in () =
  expect_validation_failure (well_formed_cmd ~burn_in:(-1) ())

let test_rejects_z_entry_not_above_z_exit () =
  expect_validation_failure (well_formed_cmd ~z_entry:"0.5" ~z_exit:"1.0" ())

let test_rejects_negative_prior_variance () =
  expect_validation_failure (well_formed_cmd ~prior_variance:"-0.1" ())

let test_rejects_zero_prior_variance () =
  expect_validation_failure (well_formed_cmd ~prior_variance:"0" ())

let test_rejects_negative_prior_beta () =
  expect_validation_failure (well_formed_cmd ~prior_beta:"-0.5" ())

let test_rejects_zero_prior_beta () =
  expect_validation_failure (well_formed_cmd ~prior_beta:"0" ())

let test_rejects_malformed_instrument () =
  expect_validation_failure (well_formed_cmd ~a:"not-qualified" ())

let test_rejects_non_decimal_discount () =
  expect_validation_failure (well_formed_cmd ~discount:"foo" ())

let test_rejects_empty_book_id () =
  expect_validation_failure (well_formed_cmd ~book:"" ())

let tests =
  [
    Alcotest.test_case "happy path persists state" `Quick test_happy_path_persists;
    Alcotest.test_case "second define replaces first" `Quick test_replaces_existing;
    Alcotest.test_case "rejects pair with same legs" `Quick test_rejects_same_legs;
    Alcotest.test_case "rejects discount = 0" `Quick test_rejects_discount_at_zero;
    Alcotest.test_case "rejects discount = 1" `Quick test_rejects_discount_at_one;
    Alcotest.test_case "rejects discount > 1" `Quick test_rejects_discount_above_one;
    Alcotest.test_case "rejects negative v" `Quick test_rejects_negative_v;
    Alcotest.test_case "rejects zero v" `Quick test_rejects_zero_v;
    Alcotest.test_case "rejects negative burn_in" `Quick test_rejects_negative_burn_in;
    Alcotest.test_case "rejects |z_entry| not > |z_exit|" `Quick
      test_rejects_z_entry_not_above_z_exit;
    Alcotest.test_case "rejects negative prior_variance" `Quick
      test_rejects_negative_prior_variance;
    Alcotest.test_case "rejects zero prior_variance" `Quick
      test_rejects_zero_prior_variance;
    Alcotest.test_case "rejects negative prior_beta" `Quick
      test_rejects_negative_prior_beta;
    Alcotest.test_case "rejects zero prior_beta" `Quick test_rejects_zero_prior_beta;
    Alcotest.test_case "rejects malformed instrument" `Quick
      test_rejects_malformed_instrument;
    Alcotest.test_case "rejects non-decimal discount" `Quick
      test_rejects_non_decimal_discount;
    Alcotest.test_case "rejects empty book_id" `Quick test_rejects_empty_book_id;
  ]
