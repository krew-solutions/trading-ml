open Core
module Pm = Portfolio_management
module Risk = Pm.Risk
module Common = Pm.Common

let book = Common.Book_id.of_string "alpha"
let dec = Decimal.of_int
let dec_s = Decimal.of_string

let inst sym = Instrument.of_qualified sym

let position ~book_id instrument target_qty : Common.Target_position.t =
  { book_id; instrument; target_qty; coupling = None }

let proposal ~positions : Common.Target_proposal.t =
  { book_id = book; positions; source = "test"; proposed_at = 1L }

let mark_const_table table inst =
  match List.find_opt (fun (i, _) -> Instrument.equal i inst) table with
  | Some (_, p) -> p
  | None -> Decimal.zero

let test_per_instrument_clip_reduces_oversized_leg () =
  let limits =
    Risk.Values.Risk_limits.make ~max_per_instrument_notional:(dec 50_000)
      ~max_gross_exposure:(dec 1_000_000)
  in
  let mark = mark_const_table [ (inst "SBER@MISX", dec 100) ] in
  (* Want 800 SBER at 100 = 80 000 notional, cap at 50 000 → 500 SBER. *)
  let prop =
    proposal ~positions:[ position ~book_id:book (inst "SBER@MISX") (dec 800) ]
  in
  let clipped = Risk.Risk_policy.clip ~limits ~mark prop in
  match clipped.positions with
  | [ p ] ->
      Alcotest.(check bool)
        "qty clipped to 500" true
        (Decimal.equal p.target_qty (dec 500))
  | other ->
      Alcotest.fail (Printf.sprintf "expected one position, got %d" (List.length other))

let test_below_cap_is_unchanged () =
  let limits =
    Risk.Values.Risk_limits.make ~max_per_instrument_notional:(dec 50_000)
      ~max_gross_exposure:(dec 1_000_000)
  in
  let mark = mark_const_table [ (inst "SBER@MISX", dec 100) ] in
  let prop =
    proposal ~positions:[ position ~book_id:book (inst "SBER@MISX") (dec 100) ]
  in
  let clipped = Risk.Risk_policy.clip ~limits ~mark prop in
  match clipped.positions with
  | [ p ] ->
      Alcotest.(check bool)
        "qty unchanged at 100" true
        (Decimal.equal p.target_qty (dec 100))
  | _ -> Alcotest.fail "expected one position"

let test_negative_qty_preserves_sign () =
  let limits =
    Risk.Values.Risk_limits.make ~max_per_instrument_notional:(dec 50_000)
      ~max_gross_exposure:(dec 1_000_000)
  in
  let mark = mark_const_table [ (inst "SBER@MISX", dec 100) ] in
  let prop =
    proposal ~positions:[ position ~book_id:book (inst "SBER@MISX") (dec (-800)) ]
  in
  let clipped = Risk.Risk_policy.clip ~limits ~mark prop in
  match clipped.positions with
  | [ p ] ->
      Alcotest.(check bool)
        "qty clipped to -500" true
        (Decimal.equal p.target_qty (dec (-500)))
  | _ -> Alcotest.fail "expected one position"

let test_gross_pass_scales_legs_proportionally () =
  let limits =
    Risk.Values.Risk_limits.make ~max_per_instrument_notional:(dec 100_000)
      ~max_gross_exposure:(dec 30_000)
  in
  let mark =
    mark_const_table [ (inst "SBER@MISX", dec 100); (inst "LKOH@MISX", dec 100) ]
  in
  (* Per-instrument: each leg 500 × 100 = 50 000 ≤ 100 000 OK. Gross
     sum 100 000 > 30 000 → scale by 0.3. *)
  let prop =
    proposal
      ~positions:
        [
          position ~book_id:book (inst "SBER@MISX") (dec 500);
          position ~book_id:book (inst "LKOH@MISX") (dec 500);
        ]
  in
  let clipped = Risk.Risk_policy.clip ~limits ~mark prop in
  let qty_of sym =
    match
      List.find_opt
        (fun (p : Common.Target_position.t) -> Instrument.equal p.instrument (inst sym))
        clipped.positions
    with
    | Some p -> p.target_qty
    | None -> Decimal.zero
  in
  Alcotest.(check bool)
    "SBER scaled to 150" true
    (Decimal.equal (qty_of "SBER@MISX") (dec 150));
  Alcotest.(check bool)
    "LKOH scaled to 150" true
    (Decimal.equal (qty_of "LKOH@MISX") (dec 150))

let coupled_position ~book_id instrument target_qty coupling : Common.Target_position.t =
  { book_id; instrument; target_qty; coupling = Some coupling }

let test_coupling_group_preserves_ratio_under_per_instrument_clip () =
  let cpl = Common.Coupling.make ~source:"pair-test" 1L in
  let limits =
    Risk.Values.Risk_limits.make ~max_per_instrument_notional:(dec 50_000)
      ~max_gross_exposure:(dec 1_000_000)
  in
  let mark =
    mark_const_table [ (inst "SBER@MISX", dec 100); (inst "LKOH@MISX", dec 100) ]
  in
  (* Leg A 800 × 100 = 80 000 > 50 000 (worst offender; needs 0.625 scale).
     Leg B 400 × 100 = 40 000 ≤ 50 000 — independently would survive.
     With per-instrument coupling-aware clip, both legs scale by 0.625:
       A → 500 (50 000 notional)
       B → 250 (25 000 notional)
     |qty_A| / |qty_B| stays at 2, the original ratio. *)
  let prop =
    proposal
      ~positions:
        [
          coupled_position ~book_id:book (inst "SBER@MISX") (dec 800) cpl;
          coupled_position ~book_id:book (inst "LKOH@MISX") (dec (-400)) cpl;
        ]
  in
  let clipped = Risk.Risk_policy.clip ~limits ~mark prop in
  let qty_of sym =
    match
      List.find_opt
        (fun (p : Common.Target_position.t) -> Instrument.equal p.instrument (inst sym))
        clipped.positions
    with
    | Some p -> p.target_qty
    | None -> Decimal.zero
  in
  let qa = qty_of "SBER@MISX" in
  let qb = qty_of "LKOH@MISX" in
  Alcotest.(check bool) "leg A scaled to 500" true (Decimal.equal qa (dec 500));
  Alcotest.(check bool) "leg B scaled to -250" true (Decimal.equal qb (dec (-250)));
  let ratio = Decimal.div (Decimal.abs qa) (Decimal.abs qb) in
  Alcotest.(check bool) "|qa|/|qb| = 2 preserved" true (Decimal.equal ratio (dec 2))

let test_independent_legs_clipped_separately () =
  let limits =
    Risk.Values.Risk_limits.make ~max_per_instrument_notional:(dec 50_000)
      ~max_gross_exposure:(dec 1_000_000)
  in
  let mark =
    mark_const_table [ (inst "SBER@MISX", dec 100); (inst "LKOH@MISX", dec 100) ]
  in
  (* Independent legs: SBER overcap → clipped to 500. LKOH under → unchanged. *)
  let prop =
    proposal
      ~positions:
        [
          position ~book_id:book (inst "SBER@MISX") (dec 800);
          position ~book_id:book (inst "LKOH@MISX") (dec 400);
        ]
  in
  let clipped = Risk.Risk_policy.clip ~limits ~mark prop in
  let qty_of sym =
    match
      List.find_opt
        (fun (p : Common.Target_position.t) -> Instrument.equal p.instrument (inst sym))
        clipped.positions
    with
    | Some p -> p.target_qty
    | None -> Decimal.zero
  in
  Alcotest.(check bool)
    "SBER clipped to 500" true
    (Decimal.equal (qty_of "SBER@MISX") (dec 500));
  Alcotest.(check bool)
    "LKOH untouched at 400" true
    (Decimal.equal (qty_of "LKOH@MISX") (dec 400))

let test_make_rejects_negative_per_instrument () =
  let raised =
    try
      let _ =
        Risk.Values.Risk_limits.make ~max_per_instrument_notional:(dec_s "-1")
          ~max_gross_exposure:(dec_s "100")
      in
      false
    with Invalid_argument _ -> true
  in
  Alcotest.(check bool) "rejected" true raised

let tests =
  [
    ( "per-instrument clip reduces oversized leg",
      `Quick,
      test_per_instrument_clip_reduces_oversized_leg );
    ("below cap is unchanged", `Quick, test_below_cap_is_unchanged);
    ("negative qty preserves sign", `Quick, test_negative_qty_preserves_sign);
    ( "gross pass scales legs proportionally",
      `Quick,
      test_gross_pass_scales_legs_proportionally );
    ( "make rejects negative per-instrument",
      `Quick,
      test_make_rejects_negative_per_instrument );
    ( "coupling group preserves ratio under per-instrument clip",
      `Quick,
      test_coupling_group_preserves_ratio_under_per_instrument_clip );
    ( "independent legs clipped separately",
      `Quick,
      test_independent_legs_clipped_separately );
  ]
