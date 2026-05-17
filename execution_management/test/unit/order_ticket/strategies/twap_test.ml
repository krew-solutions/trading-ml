(** Unit tests for the TWAP strategy. Pure-domain; no engine,
    no bus. *)

module Ot = Execution_management.Order_ticket
module Twap = Ot.Strategies.Twap
module Input = Ot.Strategies.Input
module Decision = Ot.Strategies.Decision
module Values = Ot.Values
module Placement = Ot.Placement

let qty s = Decimal.of_string s

let intent_total qty_s =
  let instrument =
    Core.Instrument.make ~ticker:(Core.Ticker.of_string "SBER")
      ~venue:(Core.Mic.of_string "MISX") ()
  in
  Values.Trade_intent.make ~book_id:"alpha" ~instrument ~side:Core.Side.Buy
    ~total_quantity:(qty qty_s)

let twap_params ~n_slices ~window_seconds ~start_at =
  Values.Twap_params.make ~n_slices ~window_seconds ~start_at

let tick now = Input.Tick { now }

let test_init_emits_no_immediate_submit () =
  let intent = intent_total "100" in
  let params = twap_params ~n_slices:4 ~window_seconds:60 ~start_at:1_000L in
  let _state, decision = Twap.init ~intent ~params ~now:1_000L in
  Alcotest.(check int) "no submit at init" 0 (List.length decision.submit);
  match decision.terminal with
  | Decision.Continue -> ()
  | _ -> Alcotest.fail "init should be Continue"

let test_first_tick_at_start_emits_first_slice () =
  let intent = intent_total "100" in
  let params = twap_params ~n_slices:4 ~window_seconds:60 ~start_at:1_000L in
  let state, _ = Twap.init ~intent ~params ~now:1_000L in
  let _state', decision = Twap.on_event state (tick 1_000L) ~now:1_000L in
  Alcotest.(check int) "one submit" 1 (List.length decision.submit);
  Alcotest.(check string) "quantity = 25" "25"
    (Decimal.to_string (List.hd decision.submit).quantity)

let test_tick_before_due_emits_nothing () =
  let intent = intent_total "100" in
  let params = twap_params ~n_slices:4 ~window_seconds:60 ~start_at:1_000L in
  let state, _ = Twap.init ~intent ~params ~now:1_000L in
  let _state', decision = Twap.on_event state (tick 999L) ~now:999L in
  Alcotest.(check int) "no submit before start" 0 (List.length decision.submit)

let test_full_schedule_sums_to_total () =
  let intent = intent_total "100" in
  let params = twap_params ~n_slices:4 ~window_seconds:60 ~start_at:1_000L in
  let state, _ = Twap.init ~intent ~params ~now:1_000L in
  let state_ref = ref state in
  let total = ref Decimal.zero in
  let ts = ref 1_000L in
  for _ = 1 to 4 do
    let state', decision = Twap.on_event !state_ref (tick !ts) ~now:!ts in
    state_ref := state';
    List.iter
      (fun (r : Decision.submit_request) -> total := Decimal.add !total r.quantity)
      decision.submit;
    ts := Int64.add !ts 15L
  done;
  Alcotest.(check string) "Σ slice_qty = total" "100"
    (Decimal.to_string !total);
  Alcotest.(check bool) "complete after all slices emitted" true
    (Twap.is_complete !state_ref)

let test_indivisible_total_residue_on_last_slice () =
  (* 100 / 3 = 33.33333333 + 33.33333333 + 33.33333334 (residue) *)
  let intent = intent_total "100" in
  let params = twap_params ~n_slices:3 ~window_seconds:60 ~start_at:1_000L in
  let state, _ = Twap.init ~intent ~params ~now:1_000L in
  let state_ref = ref state in
  let total = ref Decimal.zero in
  let ts = ref 1_000L in
  for _ = 1 to 3 do
    let state', decision = Twap.on_event !state_ref (tick !ts) ~now:!ts in
    state_ref := state';
    List.iter
      (fun (r : Decision.submit_request) -> total := Decimal.add !total r.quantity)
      decision.submit;
    ts := Int64.add !ts 20L
  done;
  Alcotest.(check string) "Σ = total exactly even when not divisible" "100"
    (Decimal.to_string !total)

let test_rejection_terminates_failed () =
  let intent = intent_total "100" in
  let params = twap_params ~n_slices:4 ~window_seconds:60 ~start_at:1_000L in
  let state, _ = Twap.init ~intent ~params ~now:1_000L in
  let state, _ = Twap.on_event state (tick 1_000L) ~now:1_000L in
  let pid = Placement.Values.Placement_id.of_int 1 in
  let _state', decision =
    Twap.on_event state
      (Input.Placement_rejected { placement_id = pid; reason = "slice 1 refused" })
      ~now:1_015L
  in
  match decision.terminal with
  | Decision.Failed _ -> ()
  | _ -> Alcotest.fail "rejection should terminate Failed"

let test_ticks_past_completion_are_noops () =
  let intent = intent_total "100" in
  let params = twap_params ~n_slices:2 ~window_seconds:60 ~start_at:1_000L in
  let state, _ = Twap.init ~intent ~params ~now:1_000L in
  let state, _ = Twap.on_event state (tick 1_000L) ~now:1_000L in
  let state, _ = Twap.on_event state (tick 1_030L) ~now:1_030L in
  let _state', decision = Twap.on_event state (tick 1_060L) ~now:1_060L in
  Alcotest.(check int) "no submit after schedule done" 0
    (List.length decision.submit)

let tests =
  [
    Alcotest.test_case "init emits no immediate submit" `Quick
      test_init_emits_no_immediate_submit;
    Alcotest.test_case "first tick at start emits first slice" `Quick
      test_first_tick_at_start_emits_first_slice;
    Alcotest.test_case "tick before due emits nothing" `Quick
      test_tick_before_due_emits_nothing;
    Alcotest.test_case "full schedule sums to total" `Quick
      test_full_schedule_sums_to_total;
    Alcotest.test_case "indivisible total → residue on last slice" `Quick
      test_indivisible_total_residue_on_last_slice;
    Alcotest.test_case "rejection terminates Failed" `Quick
      test_rejection_terminates_failed;
    Alcotest.test_case "ticks past completion are noops" `Quick
      test_ticks_past_completion_are_noops;
  ]
