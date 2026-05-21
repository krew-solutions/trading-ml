(** Unit tests for {!Equity_proportional} sizing policy. *)

open Core
module SP = Portfolio_management.Sizing_policy.Equity_proportional
module CI = Portfolio_management.Common.Construction_intent
module Source = Portfolio_management.Common.Source
module Strength = Portfolio_management.Common.Strength
module Coupling = Portfolio_management.Common.Coupling
module Direction = Portfolio_management.Common.Direction
module Book_id = Portfolio_management.Common.Book_id
module Pair = Portfolio_management.Common.Pair
module Alpha_source_id = Portfolio_management.Common.Alpha_source_id

let book () = Book_id.of_string "book-α"
let inst sym = Instrument.of_qualified sym
let dec = Decimal.of_string
let alpha_source () = Source.Alpha_view (Alpha_source_id.of_string "test-source")

let const_mark table =
 fun i ->
  match List.find_opt (fun (s, _) -> Instrument.equal s i) table with
  | Some (_, p) -> p
  | None -> Decimal.zero

let no_vol _ = None

(* ------------------------------ Scalar ------------------------------- *)

let test_scalar_up_qty () =
  let i = inst "SBER@MISX" in
  let intent =
    CI.scalar ~book_id:(book ()) ~instrument:i ~direction:Direction.Up
      ~strength:(Strength.of_decimal (dec "0.5"))
      ~source:(alpha_source ()) ~observed_at:1L
  in
  let proposal =
    SP.size () ~book_equity:(dec "100000")
      ~mark:(const_mark [ (i, dec "100") ])
      ~volatility:no_vol intent
  in
  match proposal.positions with
  | [ pos ] ->
      (* 100000 × 0.5 / 100 = 500 *)
      Alcotest.(check string) "qty" "500" (Decimal.to_string pos.target_qty);
      Alcotest.(check bool) "no coupling" true (pos.coupling = None)
  | _ -> Alcotest.fail "expected single position"

let test_scalar_down_negative_qty () =
  let i = inst "SBER@MISX" in
  let intent =
    CI.scalar ~book_id:(book ()) ~instrument:i ~direction:Direction.Down
      ~strength:(Strength.of_decimal (dec "0.5"))
      ~source:(alpha_source ()) ~observed_at:1L
  in
  let proposal =
    SP.size () ~book_equity:(dec "100000")
      ~mark:(const_mark [ (i, dec "100") ])
      ~volatility:no_vol intent
  in
  match proposal.positions with
  | [ pos ] -> Alcotest.(check string) "qty" "-500" (Decimal.to_string pos.target_qty)
  | _ -> Alcotest.fail "expected single position"

let test_scalar_flat_zero_qty () =
  let i = inst "SBER@MISX" in
  let intent =
    CI.scalar ~book_id:(book ()) ~instrument:i ~direction:Direction.Flat
      ~strength:Strength.one ~source:(alpha_source ()) ~observed_at:1L
  in
  let proposal =
    SP.size () ~book_equity:(dec "100000")
      ~mark:(const_mark [ (i, dec "100") ])
      ~volatility:no_vol intent
  in
  match proposal.positions with
  | [ pos ] -> Alcotest.(check string) "qty" "0" (Decimal.to_string pos.target_qty)
  | _ -> Alcotest.fail "expected single position"

let test_scalar_nonpositive_mark_zero_qty () =
  let i = inst "SBER@MISX" in
  let intent =
    CI.scalar ~book_id:(book ()) ~instrument:i ~direction:Direction.Up
      ~strength:Strength.one ~source:(alpha_source ()) ~observed_at:1L
  in
  let proposal =
    SP.size () ~book_equity:(dec "100000")
      ~mark:(const_mark [ (i, Decimal.zero) ])
      ~volatility:no_vol intent
  in
  match proposal.positions with
  | [ pos ] -> Alcotest.(check string) "qty" "0" (Decimal.to_string pos.target_qty)
  | _ -> Alcotest.fail "expected single position"

let test_scalar_zero_equity_zero_qty () =
  let i = inst "SBER@MISX" in
  let intent =
    CI.scalar ~book_id:(book ()) ~instrument:i ~direction:Direction.Up
      ~strength:Strength.one ~source:(alpha_source ()) ~observed_at:1L
  in
  let proposal =
    SP.size () ~book_equity:Decimal.zero
      ~mark:(const_mark [ (i, dec "100") ])
      ~volatility:no_vol intent
  in
  match proposal.positions with
  | [ pos ] -> Alcotest.(check string) "qty" "0" (Decimal.to_string pos.target_qty)
  | _ -> Alcotest.fail "expected single position"

(* ------------------------------ Coupled ----------------------------- *)

let test_coupled_pair_preserves_ratio () =
  let a = inst "SBER@MISX" in
  let b = inst "GAZP@MISX" in
  (* β=2 ⇒ a long 1/3, b short 2/3 (signed normalisation) *)
  let intent =
    CI.coupled ~book_id:(book ())
      ~legs:
        [
          { instrument = a; weight = dec "0.333333" };
          { instrument = b; weight = dec "-0.666666" };
        ]
      ~coupling:(Coupling.make ~source:"test" 1L)
      ~source:(Source.Pair_mean_reversion (Pair.make ~a ~b))
      ~observed_at:1L
  in
  let proposal =
    SP.size () ~book_equity:(dec "300000")
      ~mark:(const_mark [ (a, dec "100"); (b, dec "100") ])
      ~volatility:no_vol intent
  in
  (* Positions sorted by instrument name (GAZP < SBER). *)
  match proposal.positions with
  | [ p1; p2 ] ->
      let by_inst =
       fun ps i ->
        List.find
          (fun (p : Portfolio_management.Common.Target_position.t) ->
            Instrument.equal p.instrument i)
          ps
      in
      let pa = by_inst [ p1; p2 ] a in
      let pb = by_inst [ p1; p2 ] b in
      (* 300000 × 0.333333 / 100 = 999.999 ; ÷ 666.666 = 1500.. *)
      (* Approximate: ratio |qty_b| / |qty_a| ≈ 2 *)
      let ratio = Decimal.div (Decimal.abs pb.target_qty) (Decimal.abs pa.target_qty) in
      Alcotest.(check bool)
        "|qty_b| / |qty_a| ≈ 2" true
        (Decimal.compare ratio (dec "1.999") > 0
        && Decimal.compare ratio (dec "2.001") < 0);
      Alcotest.(check bool) "coupling on a" true (pa.coupling <> None);
      Alcotest.(check bool) "coupling on b" true (pb.coupling <> None);
      let same =
        match (pa.coupling, pb.coupling) with
        | Some ca, Some cb -> Coupling.equal ca cb
        | _ -> false
      in
      Alcotest.(check bool) "same coupling id" true same
  | _ -> Alcotest.fail "expected two positions"

let test_coupled_signs_match_weight_signs () =
  let a = inst "SBER@MISX" in
  let b = inst "GAZP@MISX" in
  let intent =
    CI.coupled ~book_id:(book ())
      ~legs:
        [
          { instrument = a; weight = dec "0.5" }; { instrument = b; weight = dec "-0.5" };
        ]
      ~coupling:(Coupling.make 2L)
      ~source:(Source.Pair_mean_reversion (Pair.make ~a ~b))
      ~observed_at:2L
  in
  let proposal =
    SP.size () ~book_equity:(dec "100000")
      ~mark:(const_mark [ (a, dec "100"); (b, dec "100") ])
      ~volatility:no_vol intent
  in
  let pa =
    List.find
      (fun (p : Portfolio_management.Common.Target_position.t) ->
        Instrument.equal p.instrument a)
      proposal.positions
  in
  let pb =
    List.find
      (fun (p : Portfolio_management.Common.Target_position.t) ->
        Instrument.equal p.instrument b)
      proposal.positions
  in
  Alcotest.(check bool) "pa positive" true (Decimal.is_positive pa.target_qty);
  Alcotest.(check bool) "pb negative" true (Decimal.is_negative pb.target_qty)

let tests =
  [
    Alcotest.test_case "Scalar Up produces positive qty" `Quick test_scalar_up_qty;
    Alcotest.test_case "Scalar Down produces negative qty" `Quick
      test_scalar_down_negative_qty;
    Alcotest.test_case "Scalar Flat → zero qty regardless of strength" `Quick
      test_scalar_flat_zero_qty;
    Alcotest.test_case "Non-positive mark → zero qty sentinel" `Quick
      test_scalar_nonpositive_mark_zero_qty;
    Alcotest.test_case "Zero book_equity → zero qty" `Quick
      test_scalar_zero_equity_zero_qty;
    Alcotest.test_case "Coupled pair preserves |w_b|/|w_a| ratio" `Quick
      test_coupled_pair_preserves_ratio;
    Alcotest.test_case "Coupled signs match weight signs" `Quick
      test_coupled_signs_match_weight_signs;
  ]
