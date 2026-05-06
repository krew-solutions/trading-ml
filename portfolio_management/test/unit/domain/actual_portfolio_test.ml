open Core
module Pm = Portfolio_management
module Actual_portfolio = Pm.Actual_portfolio
module Common = Pm.Common

let book = Common.Book_id.of_string "alpha"

let dec = Decimal.of_int

let inst sym = Instrument.of_qualified sym

let test_empty_actual_portfolio () =
  let p = Actual_portfolio.empty book in
  Alcotest.(check int) "no positions" 0 (List.length (Actual_portfolio.positions p));
  Alcotest.(check bool) "cash zero" true (Decimal.is_zero (Actual_portfolio.cash p));
  Alcotest.(check bool)
    "missing position = 0" true
    (Decimal.is_zero (Actual_portfolio.position p (inst "SBER@MISX")))

let test_apply_position_change_records_state () =
  let p = Actual_portfolio.empty book in
  let p', ev =
    Actual_portfolio.apply_position_change p ~instrument:(inst "SBER@MISX")
      ~delta_qty:(dec 5) ~new_qty:(dec 5) ~avg_price:(dec 100) ~occurred_at:1L
  in
  Alcotest.(check bool)
    "position equals new_qty" true
    (Decimal.equal (dec 5) (Actual_portfolio.position p' (inst "SBER@MISX")));
  Alcotest.(check bool) "event delta echoed" true (Decimal.equal (dec 5) ev.delta_qty);
  Alcotest.(check bool) "event new_qty echoed" true (Decimal.equal (dec 5) ev.new_qty)

let test_zero_new_qty_prunes_position () =
  let p = Actual_portfolio.empty book in
  let p, _ =
    Actual_portfolio.apply_position_change p ~instrument:(inst "SBER@MISX")
      ~delta_qty:(dec 5) ~new_qty:(dec 5) ~avg_price:(dec 100) ~occurred_at:1L
  in
  let p, _ =
    Actual_portfolio.apply_position_change p ~instrument:(inst "SBER@MISX")
      ~delta_qty:(dec (-5)) ~new_qty:Decimal.zero ~avg_price:(dec 100) ~occurred_at:2L
  in
  Alcotest.(check int)
    "no positions after closing" 0
    (List.length (Actual_portfolio.positions p));
  Alcotest.(check bool)
    "position lookup yields zero" true
    (Decimal.is_zero (Actual_portfolio.position p (inst "SBER@MISX")))

let test_apply_cash_change_overwrites_balance () =
  let p = Actual_portfolio.empty book in
  let p', ev =
    Actual_portfolio.apply_cash_change p ~delta:(dec 1000) ~new_balance:(dec 1000)
      ~occurred_at:1L
  in
  Alcotest.(check bool)
    "cash equals new_balance" true
    (Decimal.equal (dec 1000) (Actual_portfolio.cash p'));
  Alcotest.(check bool)
    "event new_balance echoed" true
    (Decimal.equal (dec 1000) ev.new_balance)

let tests =
  [
    ("empty actual_portfolio", `Quick, test_empty_actual_portfolio);
    ( "apply_position_change records state",
      `Quick,
      test_apply_position_change_records_state );
    ("zero new_qty prunes position", `Quick, test_zero_new_qty_prunes_position);
    ( "apply_cash_change overwrites balance",
      `Quick,
      test_apply_cash_change_overwrites_balance );
  ]
