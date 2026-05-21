(** Unit tests for {!Define_pair_mr_command_handler}. *)

module Pm = Portfolio_management
module DPM = Portfolio_management_commands.Define_pair_mr_command
module H = Portfolio_management_commands.Define_pair_mr_command_handler

let well_formed_cmd
    ?(book = "book-α")
    ?(a = "SBER@MISX")
    ?(b = "GAZP@MISX")
    ?(hedge = "1.0")
    ?(window = 50)
    ?(z_entry = "2.0")
    ?(z_exit = "0.5")
    () : DPM.t =
  { book_id = book; a; b; hedge_ratio = hedge; window; z_entry; z_exit }

let make_registry () =
  let tbl :
      (Pm.Common.Book_id.t * Pm.Common.Pair.t, Pm.Pair_mean_reversion.state) Hashtbl.t =
    Hashtbl.create 4
  in
  let persist ~book_id ~pair ~state = Hashtbl.replace tbl (book_id, pair) state in
  (tbl, persist)

let expect_validation_failure cmd =
  let _, persist = make_registry () in
  match H.handle ~persist_pair_mr_state:persist cmd with
  | Error _ -> ()
  | Ok () -> Alcotest.fail "expected Error"

let test_happy_path_persists () =
  let tbl, persist = make_registry () in
  match H.handle ~persist_pair_mr_state:persist (well_formed_cmd ()) with
  | Ok () -> Alcotest.(check int) "one entry" 1 (Hashtbl.length tbl)
  | Error _ -> Alcotest.fail "expected Ok"

let test_replaces_existing () =
  let tbl, persist = make_registry () in
  let _ = H.handle ~persist_pair_mr_state:persist (well_formed_cmd ~window:50 ()) in
  let _ = H.handle ~persist_pair_mr_state:persist (well_formed_cmd ~window:80 ()) in
  Alcotest.(check int) "still one entry (replaced)" 1 (Hashtbl.length tbl)

let test_rejects_same_legs () =
  expect_validation_failure (well_formed_cmd ~a:"SBER@MISX" ~b:"SBER@MISX" ())

let test_rejects_negative_hedge_ratio () =
  expect_validation_failure (well_formed_cmd ~hedge:"-0.5" ())

let test_rejects_zero_hedge_ratio () =
  expect_validation_failure (well_formed_cmd ~hedge:"0" ())

let test_rejects_zero_window () = expect_validation_failure (well_formed_cmd ~window:0 ())

let test_rejects_z_entry_not_above_z_exit () =
  (* hysteresis invariant: |z_entry| > |z_exit| *)
  expect_validation_failure (well_formed_cmd ~z_entry:"0.5" ~z_exit:"1.0" ())

let test_rejects_malformed_instrument () =
  expect_validation_failure (well_formed_cmd ~a:"not-qualified" ())

let test_rejects_non_decimal_hedge () =
  expect_validation_failure (well_formed_cmd ~hedge:"foo" ())

let tests =
  [
    Alcotest.test_case "happy path persists state" `Quick test_happy_path_persists;
    Alcotest.test_case "second define replaces first" `Quick test_replaces_existing;
    Alcotest.test_case "rejects pair with same legs" `Quick test_rejects_same_legs;
    Alcotest.test_case "rejects negative hedge_ratio" `Quick
      test_rejects_negative_hedge_ratio;
    Alcotest.test_case "rejects zero hedge_ratio" `Quick test_rejects_zero_hedge_ratio;
    Alcotest.test_case "rejects zero window" `Quick test_rejects_zero_window;
    Alcotest.test_case "rejects |z_entry| not > |z_exit|" `Quick
      test_rejects_z_entry_not_above_z_exit;
    Alcotest.test_case "rejects malformed instrument" `Quick
      test_rejects_malformed_instrument;
    Alcotest.test_case "rejects non-decimal hedge_ratio" `Quick
      test_rejects_non_decimal_hedge;
  ]
