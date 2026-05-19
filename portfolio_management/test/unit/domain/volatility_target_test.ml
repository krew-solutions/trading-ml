(** Unit tests for {!Volatility_target} sizing policy. *)

open Core
module VT = Portfolio_management.Sizing_policy.Volatility_target
module CI = Portfolio_management.Common.Construction_intent
module Source = Portfolio_management.Common.Source
module Strength = Portfolio_management.Common.Strength
module Direction = Portfolio_management.Common.Direction
module Book_id = Portfolio_management.Common.Book_id
module Alpha_source_id = Portfolio_management.Common.Alpha_source_id

let book () = Book_id.of_string "book-α"
let inst sym = Instrument.of_qualified sym
let dec = Decimal.of_string

let alpha_source () = Source.Alpha_view (Alpha_source_id.of_string "vt-test")

let const table x =
  match List.find_opt (fun (k, _) -> Instrument.equal k x) table with
  | Some (_, v) -> v
  | None -> Decimal.zero

let cfg_target vol = ({ target_annual_vol = dec vol } : VT.config)

let scalar_intent ~instrument ~direction ~strength =
  CI.scalar ~book_id:(book ()) ~instrument ~direction
    ~strength:(Strength.of_decimal strength) ~source:(alpha_source ())
    ~observed_at:1L

let test_zero_qty_when_vol_unknown () =
  let i = inst "SBER@MISX" in
  let intent =
    scalar_intent ~instrument:i ~direction:Direction.Up ~strength:(dec "0.5")
  in
  let proposal =
    VT.size (cfg_target "0.10")
      ~book_equity:(dec "100000")
      ~mark:(const [ (i, dec "100") ])
      ~volatility:(fun _ -> None)
      intent
  in
  match proposal.positions with
  | [ pos ] ->
      Alcotest.(check string) "qty 0 when vol unknown" "0"
        (Decimal.to_string pos.target_qty)
  | _ -> Alcotest.fail "single position"

let test_zero_qty_when_vol_is_zero () =
  let i = inst "SBER@MISX" in
  let intent =
    scalar_intent ~instrument:i ~direction:Direction.Up ~strength:(dec "0.5")
  in
  let proposal =
    VT.size (cfg_target "0.10")
      ~book_equity:(dec "100000")
      ~mark:(const [ (i, dec "100") ])
      ~volatility:(fun _ -> Some Decimal.zero)
      intent
  in
  match proposal.positions with
  | [ pos ] ->
      Alcotest.(check string) "qty 0 when sigma=0" "0"
        (Decimal.to_string pos.target_qty)
  | _ -> Alcotest.fail "single position"

let test_target_vol_matches_instrument_vol () =
  (* Special case: target_vol = instrument_vol → vol_scale = 1
     → reduces to Equity_proportional formula:
       qty = book_equity × weight / mark
     = 100_000 × 0.5 / 100 = 500. *)
  let i = inst "SBER@MISX" in
  let intent =
    scalar_intent ~instrument:i ~direction:Direction.Up ~strength:(dec "0.5")
  in
  let proposal =
    VT.size (cfg_target "0.20")
      ~book_equity:(dec "100000")
      ~mark:(const [ (i, dec "100") ])
      ~volatility:(fun _ -> Some (dec "0.20"))
      intent
  in
  match proposal.positions with
  | [ pos ] ->
      Alcotest.(check string) "qty 500" "500" (Decimal.to_string pos.target_qty)
  | _ -> Alcotest.fail "single position"

let test_lower_vol_gets_larger_position () =
  (* target 20%, instrument 10% → vol_scale = 2 → position 2× as
     large as the matched case. 100_000 × 0.5 × 2 / 100 = 1000. *)
  let i = inst "SBER@MISX" in
  let intent =
    scalar_intent ~instrument:i ~direction:Direction.Up ~strength:(dec "0.5")
  in
  let proposal =
    VT.size (cfg_target "0.20")
      ~book_equity:(dec "100000")
      ~mark:(const [ (i, dec "100") ])
      ~volatility:(fun _ -> Some (dec "0.10"))
      intent
  in
  match proposal.positions with
  | [ pos ] ->
      Alcotest.(check string) "qty 1000" "1000"
        (Decimal.to_string pos.target_qty)
  | _ -> Alcotest.fail "single position"

let test_higher_vol_gets_smaller_position () =
  (* target 10%, instrument 20% → vol_scale = 0.5 → half size.
     100_000 × 0.5 × 0.5 / 100 = 250. *)
  let i = inst "SBER@MISX" in
  let intent =
    scalar_intent ~instrument:i ~direction:Direction.Up ~strength:(dec "0.5")
  in
  let proposal =
    VT.size (cfg_target "0.10")
      ~book_equity:(dec "100000")
      ~mark:(const [ (i, dec "100") ])
      ~volatility:(fun _ -> Some (dec "0.20"))
      intent
  in
  match proposal.positions with
  | [ pos ] ->
      Alcotest.(check string) "qty 250" "250" (Decimal.to_string pos.target_qty)
  | _ -> Alcotest.fail "single position"

let test_zero_qty_when_mark_unknown () =
  let i = inst "SBER@MISX" in
  let intent =
    scalar_intent ~instrument:i ~direction:Direction.Up ~strength:(dec "0.5")
  in
  let proposal =
    VT.size (cfg_target "0.10")
      ~book_equity:(dec "100000")
      ~mark:(fun _ -> Decimal.zero)
      ~volatility:(fun _ -> Some (dec "0.20"))
      intent
  in
  match proposal.positions with
  | [ pos ] ->
      Alcotest.(check string) "qty 0 stale mark" "0"
        (Decimal.to_string pos.target_qty)
  | _ -> Alcotest.fail "single position"

let test_sign_follows_direction () =
  let i = inst "SBER@MISX" in
  let intent =
    scalar_intent ~instrument:i ~direction:Direction.Down ~strength:(dec "0.5")
  in
  let proposal =
    VT.size (cfg_target "0.20")
      ~book_equity:(dec "100000")
      ~mark:(const [ (i, dec "100") ])
      ~volatility:(fun _ -> Some (dec "0.20"))
      intent
  in
  match proposal.positions with
  | [ pos ] ->
      Alcotest.(check string) "qty -500 (short)" "-500"
        (Decimal.to_string pos.target_qty)
  | _ -> Alcotest.fail "single position"

let tests =
  [
    Alcotest.test_case "refuses to size when vol unknown" `Quick
      test_zero_qty_when_vol_unknown;
    Alcotest.test_case "refuses to size when sigma = 0" `Quick
      test_zero_qty_when_vol_is_zero;
    Alcotest.test_case "target_vol = instrument_vol → unit scale" `Quick
      test_target_vol_matches_instrument_vol;
    Alcotest.test_case "lower vol → larger position" `Quick
      test_lower_vol_gets_larger_position;
    Alcotest.test_case "higher vol → smaller position" `Quick
      test_higher_vol_gets_smaller_position;
    Alcotest.test_case "stale mark → qty zero" `Quick
      test_zero_qty_when_mark_unknown;
    Alcotest.test_case "Down direction yields negative qty" `Quick
      test_sign_follows_direction;
  ]
