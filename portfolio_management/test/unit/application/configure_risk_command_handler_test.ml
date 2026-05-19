(** Unit tests for {!Configure_risk_command_handler}. Exercises
    validation paths and the happy persist path against an
    in-memory registry. *)

module Pm = Portfolio_management
module CR = Portfolio_management_commands.Configure_risk_command
module H = Portfolio_management_commands.Configure_risk_command_handler

let book_str = "book-α"
let book_id = Pm.Common.Book_id.of_string book_str

let alpha_source : CR.construction_source =
  `Alpha_view { CR.alpha_source_id = "momentum-1" }

let pair_source : CR.construction_source =
  `Pair_mean_reversion { CR.a = "SBER@MISX"; b = "GAZP@MISX" }

let well_formed_cmd ?(book = book_str) ?(fraction = "0.3") ?(per_inst = "100000")
    ?(gross = "500000") ?(source = alpha_source) () : CR.t =
  {
    book_id = book;
    risk_budget_fraction = fraction;
    max_per_instrument_notional = per_inst;
    max_gross_exposure = gross;
    construction_source = source;
  }

let make_registry () =
  let tbl : (Pm.Common.Book_id.t, Pm.Risk_config.t) Hashtbl.t =
    Hashtbl.create 4
  in
  let persist bid cfg = Hashtbl.replace tbl bid cfg in
  (tbl, persist)

let test_happy_persists_alpha_source () =
  let tbl, persist = make_registry () in
  match H.handle ~persist_risk_config:persist (well_formed_cmd ()) with
  | Ok () -> (
      match Hashtbl.find_opt tbl book_id with
      | Some cfg ->
          let frac = Pm.Risk_config.risk_budget_fraction cfg in
          Alcotest.(check string) "fraction" "0.3" (Decimal.to_string frac);
          let src = Pm.Risk_config.construction_source cfg in
          let expected =
            Pm.Common.Source.Alpha_view
              (Pm.Common.Alpha_source_id.of_string "momentum-1")
          in
          Alcotest.(check bool) "alpha source" true
            (Pm.Common.Source.equal src expected)
      | None -> Alcotest.fail "registry empty after persist")
  | Error _ -> Alcotest.fail "expected Ok"

let test_happy_persists_pair_source () =
  let tbl, persist = make_registry () in
  let cmd = well_formed_cmd ~source:pair_source () in
  match H.handle ~persist_risk_config:persist cmd with
  | Ok () -> (
      match Hashtbl.find_opt tbl book_id with
      | Some cfg ->
          let src = Pm.Risk_config.construction_source cfg in
          let a = Core.Instrument.of_qualified "SBER@MISX" in
          let b = Core.Instrument.of_qualified "GAZP@MISX" in
          let expected =
            Pm.Common.Source.Pair_mean_reversion (Pm.Common.Pair.make ~a ~b)
          in
          Alcotest.(check bool) "pair source" true
            (Pm.Common.Source.equal src expected)
      | None -> Alcotest.fail "registry empty")
  | Error _ -> Alcotest.fail "expected Ok"

let test_replaces_existing_config () =
  let tbl, persist = make_registry () in
  let _ = H.handle ~persist_risk_config:persist (well_formed_cmd ~fraction:"0.1" ()) in
  let _ = H.handle ~persist_risk_config:persist (well_formed_cmd ~fraction:"0.8" ()) in
  match Hashtbl.find_opt tbl book_id with
  | Some cfg ->
      Alcotest.(check string) "second wins" "0.8"
        (Decimal.to_string (Pm.Risk_config.risk_budget_fraction cfg))
  | None -> Alcotest.fail "registry empty"

let expect_validation_failure cmd =
  let _, persist = make_registry () in
  match H.handle ~persist_risk_config:persist cmd with
  | Error _ -> ()
  | Ok () -> Alcotest.fail "expected Error"

let test_rejects_empty_book_id () =
  expect_validation_failure (well_formed_cmd ~book:"" ())

let test_rejects_fraction_above_one () =
  expect_validation_failure (well_formed_cmd ~fraction:"1.5" ())

let test_rejects_negative_fraction () =
  expect_validation_failure (well_formed_cmd ~fraction:"-0.1" ())

let test_rejects_non_decimal_fraction () =
  expect_validation_failure (well_formed_cmd ~fraction:"not-a-number" ())

let test_rejects_negative_limit () =
  expect_validation_failure (well_formed_cmd ~per_inst:"-1" ())

let test_rejects_pair_with_same_legs () =
  let same =
    `Pair_mean_reversion { CR.a = "SBER@MISX"; b = "SBER@MISX" }
  in
  expect_validation_failure (well_formed_cmd ~source:same ())

let test_rejects_invalid_alpha_id () =
  let bad = `Alpha_view { CR.alpha_source_id = "" } in
  expect_validation_failure (well_formed_cmd ~source:bad ())

let tests =
  [
    Alcotest.test_case "happy path persists alpha-view config" `Quick
      test_happy_persists_alpha_source;
    Alcotest.test_case "happy path persists pair config" `Quick
      test_happy_persists_pair_source;
    Alcotest.test_case "second config replaces first" `Quick
      test_replaces_existing_config;
    Alcotest.test_case "rejects empty book_id" `Quick test_rejects_empty_book_id;
    Alcotest.test_case "rejects fraction above 1" `Quick
      test_rejects_fraction_above_one;
    Alcotest.test_case "rejects negative fraction" `Quick
      test_rejects_negative_fraction;
    Alcotest.test_case "rejects non-decimal fraction" `Quick
      test_rejects_non_decimal_fraction;
    Alcotest.test_case "rejects negative limit" `Quick test_rejects_negative_limit;
    Alcotest.test_case "rejects pair with same legs" `Quick
      test_rejects_pair_with_same_legs;
    Alcotest.test_case "rejects empty alpha source id" `Quick
      test_rejects_invalid_alpha_id;
  ]
