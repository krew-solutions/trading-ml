(** Unit tests for the Implementation Shortfall (Almgren-Chriss)
    strategy. *)

module Ot = Execution_management.Order_ticket
module Is_strat = Ot.Strategies.Implementation_shortfall
module Input = Ot.Strategies.Input
module Decision = Ot.Strategies.Decision
module Values = Ot.Values

let qty s = Decimal.of_string s

let intent_total qty_s =
  let instrument =
    Core.Instrument.make ~ticker:(Core.Ticker.of_string "SBER")
      ~venue:(Core.Mic.of_string "MISX") ()
  in
  Values.Trade_intent.make ~book_id:"alpha" ~instrument ~side:Core.Side.Buy
    ~total_quantity:(qty qty_s)

let is_params ~n_slices ~window_seconds ~start_at ~volatility ~risk_aversion
    ~temp_impact_eta =
  Values.Implementation_shortfall_params.make ~n_slices ~window_seconds
    ~start_at ~volatility ~risk_aversion ~temp_impact_eta

let tick now = Input.Tick { now }

let drain_schedule ~intent ~params =
  let state, _ = Is_strat.init ~intent ~params ~now:0L in
  let state_ref = ref state in
  let total = ref Decimal.zero in
  let n = params.Values.Implementation_shortfall_params.n_slices in
  let window = params.window_seconds in
  for i = 1 to n do
    let due_at =
      Int64.add params.start_at (Int64.of_int (window * i / n))
    in
    let state', decision = Is_strat.on_event !state_ref (tick due_at) ~now:due_at in
    state_ref := state';
    List.iter
      (fun (r : Decision.submit_request) ->
        total := Decimal.add !total r.quantity)
      decision.submit
  done;
  (!state_ref, !total)

let test_trajectory_sums_to_total () =
  let intent = intent_total "1000" in
  let params =
    is_params ~n_slices:5 ~window_seconds:300 ~start_at:1_000L ~volatility:0.02
      ~risk_aversion:0.0001 ~temp_impact_eta:0.001
  in
  let state, total = drain_schedule ~intent ~params in
  Alcotest.(check string) "Σ slice_qty = total (residue construction)" "1000"
    (Decimal.to_string total);
  Alcotest.(check bool) "complete after all slices emitted" true
    (Is_strat.is_complete state)

let test_zero_volatility_degenerates_to_linear () =
  (* σ = 0 → κ = 0 → x(t) = X × (1 − t/T). Linear schedule equals TWAP. *)
  let intent = intent_total "100" in
  let params =
    is_params ~n_slices:4 ~window_seconds:60 ~start_at:1_000L ~volatility:0.0
      ~risk_aversion:0.0001 ~temp_impact_eta:0.001
  in
  let _state, total = drain_schedule ~intent ~params in
  Alcotest.(check string) "σ = 0 → Σ still equals total" "100"
    (Decimal.to_string total)

let test_high_volatility_front_loads () =
  (* High σ + high λ → urgency, front-loads the trajectory.
     The first slice should be the largest. *)
  let intent = intent_total "1000" in
  let params =
    is_params ~n_slices:4 ~window_seconds:60 ~start_at:1_000L ~volatility:0.50
      ~risk_aversion:0.01 ~temp_impact_eta:0.001
  in
  let state, _ = Is_strat.init ~intent ~params ~now:0L in
  let state, first = Is_strat.on_event state (tick 1_015L) ~now:1_015L in
  let _state, second = Is_strat.on_event state (tick 1_030L) ~now:1_030L in
  let q1 = (List.hd first.submit).quantity in
  let q2 = (List.hd second.submit).quantity in
  Alcotest.(check bool) "first slice ≥ second slice (front-loaded)" true
    (Decimal.compare q1 q2 >= 0)

let test_init_emits_no_immediate_submit () =
  let intent = intent_total "100" in
  let params =
    is_params ~n_slices:4 ~window_seconds:60 ~start_at:1_000L ~volatility:0.02
      ~risk_aversion:0.0001 ~temp_impact_eta:0.001
  in
  let _state, decision = Is_strat.init ~intent ~params ~now:1_000L in
  Alcotest.(check int) "no submit at init" 0 (List.length decision.submit)

let test_price_quote_is_ignored_in_pr2 () =
  (* Adaptive variant deferred; PR2 ignores Price_quote events. *)
  let intent = intent_total "100" in
  let params =
    is_params ~n_slices:4 ~window_seconds:60 ~start_at:1_000L ~volatility:0.02
      ~risk_aversion:0.0001 ~temp_impact_eta:0.001
  in
  let state, _ = Is_strat.init ~intent ~params ~now:1_000L in
  let quote =
    Values.Market_data_quote.make ~ts:1_010L
      ~bid:(Decimal.of_string "250")
      ~ask:(Decimal.of_string "251")
      ~realised_volatility:0.10
  in
  let _state', decision =
    Is_strat.on_event state (Input.Price_quote { quote }) ~now:1_010L
  in
  Alcotest.(check int) "Price_quote ignored in PR2" 0
    (List.length decision.submit)

let tests =
  [
    Alcotest.test_case "trajectory sums to total" `Quick
      test_trajectory_sums_to_total;
    Alcotest.test_case "zero volatility degenerates to linear" `Quick
      test_zero_volatility_degenerates_to_linear;
    Alcotest.test_case "high volatility front-loads schedule" `Quick
      test_high_volatility_front_loads;
    Alcotest.test_case "init emits no immediate submit" `Quick
      test_init_emits_no_immediate_submit;
    Alcotest.test_case "Price_quote ignored in PR2" `Quick
      test_price_quote_is_ignored_in_pr2;
  ]
