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

let test_commit_fill_records_state_atomically () =
  let p = Actual_portfolio.empty book in
  let p', ev =
    Actual_portfolio.commit_fill p ~instrument:(inst "SBER@MISX")
      ~new_position_quantity:(dec 5) ~new_avg_price:(dec 100) ~new_cash:(dec (-500))
      ~occurred_at:1L
  in
  Alcotest.(check bool)
    "position equals new_position_quantity" true
    (Decimal.equal (dec 5) (Actual_portfolio.position p' (inst "SBER@MISX")));
  Alcotest.(check bool)
    "cash equals new_cash" true
    (Decimal.equal (dec (-500)) (Actual_portfolio.cash p'));
  Alcotest.(check bool)
    "event new_position_quantity echoed" true
    (Decimal.equal (dec 5) ev.new_position_quantity);
  Alcotest.(check bool)
    "event new_cash echoed" true
    (Decimal.equal (dec (-500)) ev.new_cash)

let test_zero_new_position_quantity_prunes () =
  let p = Actual_portfolio.empty book in
  let p, _ =
    Actual_portfolio.commit_fill p ~instrument:(inst "SBER@MISX")
      ~new_position_quantity:(dec 5) ~new_avg_price:(dec 100) ~new_cash:(dec (-500))
      ~occurred_at:1L
  in
  let p, _ =
    Actual_portfolio.commit_fill p ~instrument:(inst "SBER@MISX")
      ~new_position_quantity:Decimal.zero ~new_avg_price:Decimal.zero ~new_cash:(dec 50)
      ~occurred_at:2L
  in
  Alcotest.(check int)
    "no positions after closing" 0
    (List.length (Actual_portfolio.positions p));
  Alcotest.(check bool)
    "position lookup yields zero" true
    (Decimal.is_zero (Actual_portfolio.position p (inst "SBER@MISX")));
  Alcotest.(check bool)
    "cash advanced atomically with prune" true
    (Decimal.equal (dec 50) (Actual_portfolio.cash p))

let tests =
  [
    ("empty actual_portfolio", `Quick, test_empty_actual_portfolio);
    ( "commit_fill records state atomically",
      `Quick,
      test_commit_fill_records_state_atomically );
    ("zero new_position_quantity prunes", `Quick, test_zero_new_position_quantity_prunes);
  ]
