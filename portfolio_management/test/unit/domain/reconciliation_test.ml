open Core
module Pm = Portfolio_management
module Target_portfolio = Pm.Target_portfolio
module Actual_portfolio = Pm.Actual_portfolio
module Reconciliation = Pm.Reconciliation
module Shared = Pm.Shared

let book = Shared.Book_id.of_string "alpha"

let dec = Decimal.of_int
let inst sym = Instrument.of_qualified sym

let position ~book_id instrument target_qty : Shared.Target_position.t =
  { book_id; instrument; target_qty }

let proposal ~book_id positions : Shared.Target_proposal.t =
  { book_id; positions; source = "test"; proposed_at = 1L }

let target_with positions =
  let prop = proposal ~book_id:book positions in
  match Target_portfolio.apply_proposal (Target_portfolio.empty book) prop with
  | Ok (t, _) -> t
  | Error _ -> failwith "target setup failed"

let actual_with deltas =
  List.fold_left
    (fun acc (instrument, qty) ->
      let p, _ =
        Actual_portfolio.apply_position_change acc ~instrument ~delta_qty:qty ~new_qty:qty
          ~avg_price:Decimal.one ~occurred_at:1L
      in
      p)
    (Actual_portfolio.empty book) deltas

let test_full_target_against_empty_actual () =
  let target =
    target_with
      [
        position ~book_id:book (inst "SBER@MISX") (dec 10);
        position ~book_id:book (inst "LKOH@MISX") (dec (-8));
      ]
  in
  let actual = Actual_portfolio.empty book in
  let trades = Reconciliation.diff ~target ~actual in
  Alcotest.(check int) "two trades" 2 (List.length trades);
  let by_instrument =
    List.map
      (fun (t : Shared.Trade_intent.t) ->
        (Instrument.to_qualified t.instrument, t.side, Decimal.to_string t.quantity))
      trades
  in
  Alcotest.(check bool)
    "BUY 10 SBER present" true
    (List.mem ("SBER@MISX", Side.Buy, "10") by_instrument);
  Alcotest.(check bool)
    "SELL 8 LKOH present" true
    (List.mem ("LKOH@MISX", Side.Sell, "8") by_instrument)

let test_matching_actual_yields_no_trades () =
  let target = target_with [ position ~book_id:book (inst "SBER@MISX") (dec 10) ] in
  let actual = actual_with [ (inst "SBER@MISX", dec 10) ] in
  let trades = Reconciliation.diff ~target ~actual in
  Alcotest.(check int) "no trades" 0 (List.length trades)

let test_partial_actual_emits_residual_trade () =
  let target = target_with [ position ~book_id:book (inst "SBER@MISX") (dec 10) ] in
  let actual = actual_with [ (inst "SBER@MISX", dec 7) ] in
  match Reconciliation.diff ~target ~actual with
  | [ trade ] ->
      Alcotest.(check string)
        "instrument" "SBER@MISX"
        (Instrument.to_qualified trade.instrument);
      Alcotest.(check bool) "BUY side" true (trade.side = Side.Buy);
      Alcotest.(check bool) "qty 3" true (Decimal.equal trade.quantity (dec 3))
  | other ->
      Alcotest.fail (Printf.sprintf "expected one trade, got %d" (List.length other))

let test_actual_above_target_emits_sell () =
  let target = target_with [ position ~book_id:book (inst "SBER@MISX") (dec 5) ] in
  let actual = actual_with [ (inst "SBER@MISX", dec 12) ] in
  match Reconciliation.diff ~target ~actual with
  | [ trade ] ->
      Alcotest.(check bool) "SELL side" true (trade.side = Side.Sell);
      Alcotest.(check bool) "qty 7" true (Decimal.equal trade.quantity (dec 7))
  | other ->
      Alcotest.fail (Printf.sprintf "expected one trade, got %d" (List.length other))

let test_diff_event_carries_book_and_timestamp () =
  let target = target_with [ position ~book_id:book (inst "SBER@MISX") (dec 1) ] in
  let actual = Actual_portfolio.empty book in
  let _trades, event = Reconciliation.diff_with_event ~target ~actual ~computed_at:42L in
  Alcotest.(check int64) "computed_at echoed" 42L event.computed_at;
  Alcotest.(check string) "book_id" "alpha" (Shared.Book_id.to_string event.book_id)

let tests =
  [
    ("full target against empty actual", `Quick, test_full_target_against_empty_actual);
    ("matching actual yields no trades", `Quick, test_matching_actual_yields_no_trades);
    ( "partial actual emits residual trade",
      `Quick,
      test_partial_actual_emits_residual_trade );
    ("actual above target emits sell", `Quick, test_actual_above_target_emits_sell);
    ( "diff event carries book and timestamp",
      `Quick,
      test_diff_event_carries_book_and_timestamp );
  ]
