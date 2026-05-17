(** Unit tests for the VWAP strategy. Pure-domain. *)

module Ot = Execution_management.Order_ticket
module Vwap = Ot.Strategies.Vwap
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

let vwap_params ~n_slices ~window_seconds ~start_at ~volume_profile =
  Values.Vwap_params.make ~n_slices ~window_seconds ~start_at ~volume_profile

let tick now = Input.Tick { now }

let test_schedule_follows_volume_profile () =
  (* Profile [0.1; 0.3; 0.4; 0.2] → slices 10, 30, 40, 20 from total 100. *)
  let intent = intent_total "100" in
  let params =
    vwap_params ~n_slices:4 ~window_seconds:60 ~start_at:1_000L
      ~volume_profile:[ 0.1; 0.3; 0.4; 0.2 ]
  in
  let state, _ = Vwap.init ~intent ~params ~now:1_000L in
  let state_ref = ref state in
  let qtys = ref [] in
  let ts = ref 1_000L in
  for _ = 1 to 4 do
    let state', decision = Vwap.on_event !state_ref (tick !ts) ~now:!ts in
    state_ref := state';
    List.iter
      (fun (r : Decision.submit_request) -> qtys := r.quantity :: !qtys)
      decision.submit;
    ts := Int64.add !ts 15L
  done;
  let total = List.fold_left Decimal.add Decimal.zero !qtys in
  Alcotest.(check string) "Σ slice_qty = total" "100"
    (Decimal.to_string total);
  Alcotest.(check int) "exactly 4 slices emitted" 4 (List.length !qtys)

let test_unnormalised_weights_get_normalised () =
  (* Weights [1.0; 3.0; 4.0; 2.0] sum to 10 → equivalent to
     [0.1; 0.3; 0.4; 0.2]. *)
  let intent = intent_total "100" in
  let params =
    vwap_params ~n_slices:4 ~window_seconds:60 ~start_at:1_000L
      ~volume_profile:[ 1.0; 3.0; 4.0; 2.0 ]
  in
  let state, _ = Vwap.init ~intent ~params ~now:1_000L in
  let state_ref = ref state in
  let total = ref Decimal.zero in
  let ts = ref 1_000L in
  for _ = 1 to 4 do
    let state', decision = Vwap.on_event !state_ref (tick !ts) ~now:!ts in
    state_ref := state';
    List.iter
      (fun (r : Decision.submit_request) -> total := Decimal.add !total r.quantity)
      decision.submit;
    ts := Int64.add !ts 15L
  done;
  Alcotest.(check string) "Σ = total after normalisation" "100"
    (Decimal.to_string !total)

let test_init_emits_no_immediate_submit () =
  let intent = intent_total "100" in
  let params =
    vwap_params ~n_slices:4 ~window_seconds:60 ~start_at:1_000L
      ~volume_profile:[ 0.25; 0.25; 0.25; 0.25 ]
  in
  let _state, decision = Vwap.init ~intent ~params ~now:1_000L in
  Alcotest.(check int) "no submit at init" 0 (List.length decision.submit)

let test_uniform_profile_equals_twap_quantities () =
  (* Uniform weights == TWAP equal slices. *)
  let intent = intent_total "100" in
  let params =
    vwap_params ~n_slices:4 ~window_seconds:60 ~start_at:1_000L
      ~volume_profile:[ 0.25; 0.25; 0.25; 0.25 ]
  in
  let state, _ = Vwap.init ~intent ~params ~now:1_000L in
  let _, decision = Vwap.on_event state (tick 1_000L) ~now:1_000L in
  Alcotest.(check string) "uniform → equal slices" "25"
    (Decimal.to_string (List.hd decision.submit).quantity)

let tests =
  [
    Alcotest.test_case "schedule follows volume profile" `Quick
      test_schedule_follows_volume_profile;
    Alcotest.test_case "unnormalised weights get normalised" `Quick
      test_unnormalised_weights_get_normalised;
    Alcotest.test_case "init emits no immediate submit" `Quick
      test_init_emits_no_immediate_submit;
    Alcotest.test_case "uniform profile equals TWAP quantities" `Quick
      test_uniform_profile_equals_twap_quantities;
  ]
