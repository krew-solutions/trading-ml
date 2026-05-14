(** Unit tests for {!Pre_trade_risk.Risk_view}. *)

let d = Decimal.of_string

let book = Pre_trade_risk.Common.Book_id.of_string "alpha"

let sber = Core.Instrument.of_qualified "SBER@MISX"
let lkoh = Core.Instrument.of_qualified "LKOH@MISX"

let test_empty_has_zero_cash_and_no_positions () =
  let v = Pre_trade_risk.Risk_view.empty book in
  Alcotest.(check string) "cash" "0" (Decimal.to_string (Pre_trade_risk.Risk_view.cash v));
  Alcotest.(check int) "positions" 0 (List.length (Pre_trade_risk.Risk_view.positions v))

let test_commit_fill_sets_cash_and_position () =
  let v = Pre_trade_risk.Risk_view.empty book in
  let v', _ev =
    Pre_trade_risk.Risk_view.commit_fill v ~instrument:sber
      ~new_position_quantity:(d "10") ~new_avg_price:(d "150") ~new_cash:(d "-1500")
      ~occurred_at:42L
  in
  Alcotest.(check string)
    "cash post" "-1500"
    (Decimal.to_string (Pre_trade_risk.Risk_view.cash v'));
  Alcotest.(check string)
    "qty SBER" "10"
    (Decimal.to_string (Pre_trade_risk.Risk_view.position v' sber))

let test_commit_fill_updates_existing () =
  let v = Pre_trade_risk.Risk_view.empty book in
  let v, _ =
    Pre_trade_risk.Risk_view.commit_fill v ~instrument:sber
      ~new_position_quantity:(d "10") ~new_avg_price:(d "150") ~new_cash:(d "-1500")
      ~occurred_at:1L
  in
  let v, _ =
    Pre_trade_risk.Risk_view.commit_fill v ~instrument:sber
      ~new_position_quantity:(d "15") ~new_avg_price:(d "150") ~new_cash:(d "-2250")
      ~occurred_at:2L
  in
  Alcotest.(check string)
    "qty SBER 15" "15"
    (Decimal.to_string (Pre_trade_risk.Risk_view.position v sber));
  Alcotest.(check int)
    "single entry" 1
    (List.length (Pre_trade_risk.Risk_view.positions v))

let test_commit_fill_zero_qty_prunes () =
  let v = Pre_trade_risk.Risk_view.empty book in
  let v, _ =
    Pre_trade_risk.Risk_view.commit_fill v ~instrument:sber
      ~new_position_quantity:(d "10") ~new_avg_price:(d "150") ~new_cash:(d "-1500")
      ~occurred_at:1L
  in
  let v, _ =
    Pre_trade_risk.Risk_view.commit_fill v ~instrument:sber ~new_position_quantity:(d "0")
      ~new_avg_price:(d "0") ~new_cash:(d "0") ~occurred_at:2L
  in
  Alcotest.(check int) "no entries" 0 (List.length (Pre_trade_risk.Risk_view.positions v));
  Alcotest.(check string)
    "position SBER absent" "0"
    (Decimal.to_string (Pre_trade_risk.Risk_view.position v sber))

let test_positions_sorted_deterministically () =
  let v = Pre_trade_risk.Risk_view.empty book in
  let v, _ =
    Pre_trade_risk.Risk_view.commit_fill v ~instrument:sber
      ~new_position_quantity:(d "10") ~new_avg_price:(d "150") ~new_cash:(d "-1500")
      ~occurred_at:1L
  in
  let v, _ =
    Pre_trade_risk.Risk_view.commit_fill v ~instrument:lkoh ~new_position_quantity:(d "5")
      ~new_avg_price:(d "8000") ~new_cash:(d "-41500") ~occurred_at:2L
  in
  let names =
    List.map
      (fun p ->
        Core.Ticker.to_string
          (Core.Instrument.ticker
             (Pre_trade_risk.Risk_view.Values.Position_snapshot.instrument p)))
      (Pre_trade_risk.Risk_view.positions v)
  in
  Alcotest.(check (list string)) "sorted" [ "LKOH"; "SBER" ] names

let tests =
  [
    Alcotest.test_case "empty has zero cash and no positions" `Quick
      test_empty_has_zero_cash_and_no_positions;
    Alcotest.test_case "commit_fill sets cash and position" `Quick
      test_commit_fill_sets_cash_and_position;
    Alcotest.test_case "commit_fill updates existing" `Quick
      test_commit_fill_updates_existing;
    Alcotest.test_case "commit_fill zero qty prunes" `Quick
      test_commit_fill_zero_qty_prunes;
    Alcotest.test_case "positions sorted deterministically" `Quick
      test_positions_sorted_deterministically;
  ]
