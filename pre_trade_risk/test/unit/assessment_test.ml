(** Unit tests for {!Pre_trade_risk.Assessment}. Mirrors the cases
    that lived in [strategy/test/unit/domain/engine/risk_test.ml] before
    the M1 extraction. *)

let d = Decimal.of_string

let book = Pre_trade_risk.Common.Book_id.of_string "alpha"
let sber = Core.Instrument.of_qualified "SBER@MISX"
let mark _ = None

let limits =
  Pre_trade_risk.Risk_limits.make ~min_cash_buffer:(d "0")
    ~max_gross_exposure:(d "1000000") ~max_leverage:5.0

let view_with ~cash ~positions =
  let v = Pre_trade_risk.Risk_view.empty book in
  let v, _ =
    Pre_trade_risk.Risk_view.apply_cash_change v ~delta:cash ~new_balance:cash
      ~occurred_at:0L
  in
  List.fold_left
    (fun v (instrument, qty, avg_price) ->
      let v', _ =
        Pre_trade_risk.Risk_view.apply_position_change v ~instrument ~delta_qty:qty
          ~new_qty:qty ~avg_price ~occurred_at:0L
      in
      v')
    v positions

let test_zero_quantity_rejects () =
  let view = view_with ~cash:(d "1000") ~positions:[] in
  match
    Pre_trade_risk.Assessment.assess ~view ~limits ~side:Core.Side.Buy ~instrument:sber
      ~quantity:(d "0") ~price:(d "100") ~mark
  with
  | Reject reason -> Alcotest.(check string) "reason" "zero quantity" reason
  | Approve _ -> Alcotest.fail "expected reject"

let test_zero_price_rejects () =
  let view = view_with ~cash:(d "1000") ~positions:[] in
  match
    Pre_trade_risk.Assessment.assess ~view ~limits ~side:Core.Side.Buy ~instrument:sber
      ~quantity:(d "10") ~price:(d "0") ~mark
  with
  | Reject reason -> Alcotest.(check string) "reason" "zero price" reason
  | Approve _ -> Alcotest.fail "expected reject"

let test_buy_within_limits_approves () =
  let view = view_with ~cash:(d "10000") ~positions:[] in
  match
    Pre_trade_risk.Assessment.assess ~view ~limits ~side:Core.Side.Buy ~instrument:sber
      ~quantity:(d "10") ~price:(d "150") ~mark
  with
  | Approve qty -> Alcotest.(check string) "qty" "10" (Decimal.to_string qty)
  | Reject r -> Alcotest.fail (Printf.sprintf "expected approve, got reject: %s" r)

let test_buy_breaches_min_cash_buffer () =
  let limits =
    Pre_trade_risk.Risk_limits.make ~min_cash_buffer:(d "500")
      ~max_gross_exposure:(d "1000000") ~max_leverage:5.0
  in
  let view = view_with ~cash:(d "1000") ~positions:[] in
  match
    Pre_trade_risk.Assessment.assess ~view ~limits ~side:Core.Side.Buy ~instrument:sber
      ~quantity:(d "10") ~price:(d "100") ~mark
  with
  | Reject reason ->
      Alcotest.(check string) "reason" "would breach min_cash_buffer" reason
  | Approve _ -> Alcotest.fail "expected reject"

let test_breaches_max_gross_exposure () =
  let limits =
    Pre_trade_risk.Risk_limits.make ~min_cash_buffer:(d "0")
      ~max_gross_exposure:(d "1500") ~max_leverage:50.0
  in
  let view = view_with ~cash:(d "10000") ~positions:[ (sber, d "10", d "100") ] in
  (* existing exposure = 10 * 100 = 1000; new buy 10 * 100 = 1000;
     gross' = 2000 > cap 1500. *)
  match
    Pre_trade_risk.Assessment.assess ~view ~limits ~side:Core.Side.Buy ~instrument:sber
      ~quantity:(d "10") ~price:(d "100") ~mark
  with
  | Reject reason -> Alcotest.(check string) "reason" "max_gross_exposure" reason
  | Approve _ -> Alcotest.fail "expected reject"

let test_breaches_max_leverage () =
  let limits =
    Pre_trade_risk.Risk_limits.make ~min_cash_buffer:(d "0")
      ~max_gross_exposure:(d "1000000") ~max_leverage:0.5
  in
  let view = view_with ~cash:(d "1000") ~positions:[] in
  (* equity = 1000; gross' = 10*100 = 1000; lev = 1.0 > 0.5. *)
  match
    Pre_trade_risk.Assessment.assess ~view ~limits ~side:Core.Side.Buy ~instrument:sber
      ~quantity:(d "10") ~price:(d "100") ~mark
  with
  | Reject reason -> Alcotest.(check string) "reason" "max_leverage" reason
  | Approve _ -> Alcotest.fail "expected reject"

let tests =
  [
    Alcotest.test_case "zero quantity rejects" `Quick test_zero_quantity_rejects;
    Alcotest.test_case "zero price rejects" `Quick test_zero_price_rejects;
    Alcotest.test_case "buy within limits approves" `Quick test_buy_within_limits_approves;
    Alcotest.test_case "buy breaches min_cash_buffer" `Quick
      test_buy_breaches_min_cash_buffer;
    Alcotest.test_case "breaches max_gross_exposure" `Quick
      test_breaches_max_gross_exposure;
    Alcotest.test_case "breaches max_leverage" `Quick test_breaches_max_leverage;
  ]
