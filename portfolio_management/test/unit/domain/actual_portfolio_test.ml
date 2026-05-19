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

let const_mark table =
  fun i ->
    match List.find_opt (fun (s, _) -> Instrument.equal s i) table with
    | Some (_, p) -> p
    | None -> Decimal.zero

let test_equity_cash_only_for_empty_positions () =
  let p = Actual_portfolio.empty book in
  let p', _ =
    Actual_portfolio.commit_fill p ~instrument:(inst "SBER@MISX")
      ~new_position_quantity:Decimal.zero ~new_avg_price:Decimal.zero
      ~new_cash:(dec 1000) ~occurred_at:1L
  in
  Alcotest.(check string)
    "equity = cash" "1000"
    (Decimal.to_string (Actual_portfolio.equity p' ~mark:(fun _ -> dec 100)))

let test_equity_long_position_adds_marked_value () =
  let p = Actual_portfolio.empty book in
  let p', _ =
    Actual_portfolio.commit_fill p ~instrument:(inst "SBER@MISX")
      ~new_position_quantity:(dec 10) ~new_avg_price:(dec 90)
      ~new_cash:(dec 100) ~occurred_at:1L
  in
  let mark = const_mark [ (inst "SBER@MISX", dec 110) ] in
  (* equity = 100 cash + 10 × 110 = 1200 *)
  Alcotest.(check string)
    "cash + qty × mark" "1200"
    (Decimal.to_string (Actual_portfolio.equity p' ~mark))

let test_equity_short_position_subtracts_marked_value () =
  let p = Actual_portfolio.empty book in
  let p', _ =
    Actual_portfolio.commit_fill p ~instrument:(inst "SBER@MISX")
      ~new_position_quantity:(dec (-5)) ~new_avg_price:(dec 200)
      ~new_cash:(dec 1500) ~occurred_at:1L
  in
  let mark = const_mark [ (inst "SBER@MISX", dec 100) ] in
  (* equity = 1500 cash + (-5) × 100 = 1000 *)
  Alcotest.(check string)
    "cash + signed qty × mark" "1000"
    (Decimal.to_string (Actual_portfolio.equity p' ~mark))

let test_equity_missing_mark_treats_as_zero () =
  let p = Actual_portfolio.empty book in
  let p', _ =
    Actual_portfolio.commit_fill p ~instrument:(inst "SBER@MISX")
      ~new_position_quantity:(dec 10) ~new_avg_price:(dec 90)
      ~new_cash:(dec 100) ~occurred_at:1L
  in
  let no_marks _ = Decimal.zero in
  Alcotest.(check string)
    "equity = cash only when mark unknown" "100"
    (Decimal.to_string (Actual_portfolio.equity p' ~mark:no_marks))

let tests =
  [
    ("empty actual_portfolio", `Quick, test_empty_actual_portfolio);
    ( "commit_fill records state atomically",
      `Quick,
      test_commit_fill_records_state_atomically );
    ("zero new_position_quantity prunes", `Quick, test_zero_new_position_quantity_prunes);
    ("equity = cash only for empty positions", `Quick,
      test_equity_cash_only_for_empty_positions);
    ("equity adds long marked value", `Quick,
      test_equity_long_position_adds_marked_value);
    ("equity subtracts short marked value", `Quick,
      test_equity_short_position_subtracts_marked_value);
    ("equity treats missing mark as zero", `Quick,
      test_equity_missing_mark_treats_as_zero);
  ]
