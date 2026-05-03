open Core
module Pm = Portfolio_management
module Target_portfolio = Pm.Target_portfolio
module Shared = Pm.Shared

let book = Shared.Book_id.of_string "alpha"

let inst sym = Instrument.of_qualified sym

let position ~book_id instrument target_qty : Shared.Target_position.t =
  { book_id; instrument; target_qty }

let proposal ~book_id positions : Shared.Target_proposal.t =
  { book_id; positions; source = "test"; proposed_at = 1700000000L }

let dec = Decimal.of_int

let test_empty_book_has_no_positions () =
  let p = Target_portfolio.empty book in
  Alcotest.(check (list string))
    "no positions" []
    (List.map
       (fun (tp : Shared.Target_position.t) -> Instrument.to_qualified tp.instrument)
       (Target_portfolio.positions p));
  Alcotest.(check bool)
    "target_for absent = 0" true
    (Decimal.is_zero (Target_portfolio.target_for p (inst "SBER@MISX")))

let test_apply_proposal_sets_positions () =
  let p = Target_portfolio.empty book in
  let prop =
    proposal ~book_id:book
      [
        position ~book_id:book (inst "SBER@MISX") (dec 10);
        position ~book_id:book (inst "LKOH@MISX") (dec (-8));
      ]
  in
  match Target_portfolio.apply_proposal p prop with
  | Error _ -> Alcotest.fail "expected Ok"
  | Ok (p', ev) ->
      Alcotest.(check int) "two changes recorded" 2 (List.length ev.changed);
      Alcotest.(check bool)
        "SBER target = 10" true
        (Decimal.equal (dec 10) (Target_portfolio.target_for p' (inst "SBER@MISX")));
      Alcotest.(check bool)
        "LKOH target = -8" true
        (Decimal.equal (dec (-8)) (Target_portfolio.target_for p' (inst "LKOH@MISX")))

let test_idempotent_reapplication_emits_no_changes () =
  let p = Target_portfolio.empty book in
  let prop =
    proposal ~book_id:book [ position ~book_id:book (inst "SBER@MISX") (dec 10) ]
  in
  match Target_portfolio.apply_proposal p prop with
  | Error _ -> Alcotest.fail "first apply: expected Ok"
  | Ok (p', _) -> (
      match Target_portfolio.apply_proposal p' prop with
      | Error _ -> Alcotest.fail "second apply: expected Ok"
      | Ok (p'', ev) ->
          Alcotest.(check int) "no changes second time" 0 (List.length ev.changed);
          Alcotest.(check bool)
            "SBER unchanged" true
            (Decimal.equal (dec 10) (Target_portfolio.target_for p'' (inst "SBER@MISX"))))

let test_zero_target_prunes_position () =
  let p = Target_portfolio.empty book in
  let prop_set =
    proposal ~book_id:book [ position ~book_id:book (inst "SBER@MISX") (dec 5) ]
  in
  let prop_zero =
    proposal ~book_id:book [ position ~book_id:book (inst "SBER@MISX") Decimal.zero ]
  in
  match Target_portfolio.apply_proposal p prop_set with
  | Error _ -> Alcotest.fail "first apply expected Ok"
  | Ok (p', _) -> (
      match Target_portfolio.apply_proposal p' prop_zero with
      | Error _ -> Alcotest.fail "zero apply expected Ok"
      | Ok (p'', _) ->
          Alcotest.(check int)
            "no positions after zeroing" 0
            (List.length (Target_portfolio.positions p'')))

let test_book_id_mismatch_rejected () =
  let p = Target_portfolio.empty book in
  let other = Shared.Book_id.of_string "other" in
  let prop =
    proposal ~book_id:other [ position ~book_id:other (inst "SBER@MISX") (dec 1) ]
  in
  match Target_portfolio.apply_proposal p prop with
  | Ok _ -> Alcotest.fail "expected book mismatch error"
  | Error (Target_portfolio.Book_id_mismatch _) -> ()
  | Error _ -> Alcotest.fail "expected Book_id_mismatch"

let tests =
  [
    ("empty book has no positions", `Quick, test_empty_book_has_no_positions);
    ("apply_proposal sets positions", `Quick, test_apply_proposal_sets_positions);
    ( "idempotent re-application emits no changes",
      `Quick,
      test_idempotent_reapplication_emits_no_changes );
    ("zero target prunes position", `Quick, test_zero_target_prunes_position);
    ("book_id mismatch is rejected", `Quick, test_book_id_mismatch_rejected);
  ]
