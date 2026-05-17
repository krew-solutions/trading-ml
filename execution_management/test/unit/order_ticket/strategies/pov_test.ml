(** Unit tests for the POV (Percent Of Volume) strategy. *)

module Ot = Execution_management.Order_ticket
module Pov = Ot.Strategies.Pov
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

let volume_bar ~ts ~vol =
  Values.Volume_bar.make ~ts ~volume:(Decimal.of_string vol)

let test_first_volume_bar_emits_proportional_slice () =
  let intent = intent_total "1000" in
  let params = Values.Pov_params.make ~participation_rate:0.20 in
  let state, _ = Pov.init ~intent ~params ~now:0L in
  let _state', decision =
    Pov.on_event state
      (Input.Volume_bar { bar = volume_bar ~ts:0L ~vol:"1000" })
      ~now:0L
  in
  Alcotest.(check int) "one submit" 1 (List.length decision.submit);
  Alcotest.(check string) "emit_qty = 200 (20% of 1000)" "200"
    (Decimal.to_string (List.hd decision.submit).quantity)

let test_no_volume_no_emission () =
  let intent = intent_total "1000" in
  let params = Values.Pov_params.make ~participation_rate:0.20 in
  let _state, decision = Pov.init ~intent ~params ~now:0L in
  Alcotest.(check int) "no submit at init (no volume yet)" 0
    (List.length decision.submit)

let test_cumulative_pov_respects_rate () =
  (* observed = 1000 → emit 200; observed = 1500 → cumulative target 300;
     already emitted 200, so emit 100 more. *)
  let intent = intent_total "1000" in
  let params = Values.Pov_params.make ~participation_rate:0.20 in
  let state, _ = Pov.init ~intent ~params ~now:0L in
  let state, _ =
    Pov.on_event state
      (Input.Volume_bar { bar = volume_bar ~ts:0L ~vol:"1000" })
      ~now:0L
  in
  let _state', decision =
    Pov.on_event state
      (Input.Volume_bar { bar = volume_bar ~ts:1L ~vol:"500" })
      ~now:1L
  in
  Alcotest.(check string) "incremental emit = 100" "100"
    (Decimal.to_string (List.hd decision.submit).quantity)

let test_emission_capped_by_remaining () =
  (* Total intent 100, rate 50%, volume 1000 → would emit 500 but
     capped at remaining 100. *)
  let intent = intent_total "100" in
  let params = Values.Pov_params.make ~participation_rate:0.50 in
  let state, _ = Pov.init ~intent ~params ~now:0L in
  let _state', decision =
    Pov.on_event state
      (Input.Volume_bar { bar = volume_bar ~ts:0L ~vol:"1000" })
      ~now:0L
  in
  Alcotest.(check string) "capped at remaining = 100" "100"
    (Decimal.to_string (List.hd decision.submit).quantity)

let test_tick_is_ignored () =
  let intent = intent_total "1000" in
  let params = Values.Pov_params.make ~participation_rate:0.20 in
  let state, _ = Pov.init ~intent ~params ~now:0L in
  let _state', decision =
    Pov.on_event state (Input.Tick { now = 1L }) ~now:1L
  in
  Alcotest.(check int) "tick triggers nothing in POV" 0
    (List.length decision.submit)

let test_completes_when_intent_filled () =
  let intent = intent_total "100" in
  let params = Values.Pov_params.make ~participation_rate:1.00 in
  let state, _ = Pov.init ~intent ~params ~now:0L in
  let state, _ =
    Pov.on_event state
      (Input.Volume_bar { bar = volume_bar ~ts:0L ~vol:"100" })
      ~now:0L
  in
  Alcotest.(check bool) "complete after emitting the full intent" true
    (Pov.is_complete state)

let tests =
  [
    Alcotest.test_case "first volume bar emits proportional slice" `Quick
      test_first_volume_bar_emits_proportional_slice;
    Alcotest.test_case "no volume → no emission (Disabled feed semantic)" `Quick
      test_no_volume_no_emission;
    Alcotest.test_case "cumulative POV respects rate" `Quick
      test_cumulative_pov_respects_rate;
    Alcotest.test_case "emission capped by remaining" `Quick
      test_emission_capped_by_remaining;
    Alcotest.test_case "tick is ignored" `Quick test_tick_is_ignored;
    Alcotest.test_case "completes when intent filled" `Quick
      test_completes_when_intent_filled;
  ]
