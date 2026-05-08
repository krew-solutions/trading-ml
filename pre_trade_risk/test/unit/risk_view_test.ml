(** Unit tests for {!Pre_trade_risk.Risk_view}. *)

let d = Decimal.of_string

let book = Pre_trade_risk.Common.Book_id.of_string "alpha"

let sber = Core.Instrument.of_qualified "SBER@MISX"
let lkoh = Core.Instrument.of_qualified "LKOH@MISX"

let test_empty_has_zero_cash_and_no_positions () =
  let v = Pre_trade_risk.Risk_view.empty book in
  Alcotest.(check string) "cash" "0" (Decimal.to_string (Pre_trade_risk.Risk_view.cash v));
  Alcotest.(check int) "positions" 0 (List.length (Pre_trade_risk.Risk_view.positions v))

let test_apply_cash_change_sets_balance () =
  let v = Pre_trade_risk.Risk_view.empty book in
  let v', _ev =
    Pre_trade_risk.Risk_view.apply_cash_change v ~delta:(d "100") ~new_balance:(d "100")
      ~occurred_at:42L
  in
  Alcotest.(check string)
    "cash post" "100"
    (Decimal.to_string (Pre_trade_risk.Risk_view.cash v'))

let test_apply_position_change_inserts () =
  let v = Pre_trade_risk.Risk_view.empty book in
  let v', _ev =
    Pre_trade_risk.Risk_view.apply_position_change v ~instrument:sber ~delta_qty:(d "10")
      ~new_qty:(d "10") ~avg_price:(d "150") ~occurred_at:42L
  in
  Alcotest.(check string)
    "qty SBER" "10"
    (Decimal.to_string (Pre_trade_risk.Risk_view.position v' sber))

let test_apply_position_change_updates_existing () =
  let v = Pre_trade_risk.Risk_view.empty book in
  let v, _ =
    Pre_trade_risk.Risk_view.apply_position_change v ~instrument:sber ~delta_qty:(d "10")
      ~new_qty:(d "10") ~avg_price:(d "150") ~occurred_at:1L
  in
  let v, _ =
    Pre_trade_risk.Risk_view.apply_position_change v ~instrument:sber ~delta_qty:(d "5")
      ~new_qty:(d "15") ~avg_price:(d "150") ~occurred_at:2L
  in
  Alcotest.(check string)
    "qty SBER 15" "15"
    (Decimal.to_string (Pre_trade_risk.Risk_view.position v sber));
  Alcotest.(check int)
    "single entry" 1
    (List.length (Pre_trade_risk.Risk_view.positions v))

let test_apply_position_change_zero_qty_prunes () =
  let v = Pre_trade_risk.Risk_view.empty book in
  let v, _ =
    Pre_trade_risk.Risk_view.apply_position_change v ~instrument:sber ~delta_qty:(d "10")
      ~new_qty:(d "10") ~avg_price:(d "150") ~occurred_at:1L
  in
  let v, _ =
    Pre_trade_risk.Risk_view.apply_position_change v ~instrument:sber ~delta_qty:(d "-10")
      ~new_qty:(d "0") ~avg_price:(d "150") ~occurred_at:2L
  in
  Alcotest.(check int) "no entries" 0 (List.length (Pre_trade_risk.Risk_view.positions v));
  Alcotest.(check string)
    "position SBER absent" "0"
    (Decimal.to_string (Pre_trade_risk.Risk_view.position v sber))

let test_positions_sorted_deterministically () =
  let v = Pre_trade_risk.Risk_view.empty book in
  let v, _ =
    Pre_trade_risk.Risk_view.apply_position_change v ~instrument:sber ~delta_qty:(d "10")
      ~new_qty:(d "10") ~avg_price:(d "150") ~occurred_at:1L
  in
  let v, _ =
    Pre_trade_risk.Risk_view.apply_position_change v ~instrument:lkoh ~delta_qty:(d "5")
      ~new_qty:(d "5") ~avg_price:(d "8000") ~occurred_at:2L
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
    Alcotest.test_case "apply_cash_change sets balance" `Quick
      test_apply_cash_change_sets_balance;
    Alcotest.test_case "apply_position_change inserts" `Quick
      test_apply_position_change_inserts;
    Alcotest.test_case "apply_position_change updates existing" `Quick
      test_apply_position_change_updates_existing;
    Alcotest.test_case "apply_position_change zero_qty prunes" `Quick
      test_apply_position_change_zero_qty_prunes;
    Alcotest.test_case "positions sorted deterministically" `Quick
      test_positions_sorted_deterministically;
  ]
