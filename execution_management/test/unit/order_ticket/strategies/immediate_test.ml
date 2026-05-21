(** Unit tests for the Immediate execution strategy. Pure-domain
    coverage — no engine, no bus, no clock injection beyond the
    [~now] argument. *)

module Ot = Execution_management.Order_ticket
module Imm = Ot.Strategies.Immediate
module Input = Ot.Strategies.Input
module Decision = Ot.Strategies.Decision
module Values = Ot.Values
module Placement = Ot.Placement

let qty s = Decimal.of_string s
let price s = Decimal.of_string s

let intent_buy_100 () =
  let instrument =
    Core.Instrument.make
      ~ticker:(Core.Ticker.of_string "SBER")
      ~venue:(Core.Mic.of_string "MISX") ()
  in
  Values.Trade_intent.make ~book_id:"alpha" ~instrument ~side:Core.Side.Buy
    ~total_quantity:(qty "100")

let placement_id_1 = Placement.Values.Placement_id.of_int 1

let fill ~quantity ~price ~fee =
  Placement.Values.Fill_record.make ~quantity:(qty quantity)
    ~price:(Decimal.of_string price) ~fee:(Decimal.of_string fee) ~ts:1_700_000_000L

let test_init_emits_single_submit_with_full_quantity () =
  let intent = intent_buy_100 () in
  let _state, decision = Imm.init ~intent ~now:1_700_000_000L in
  Alcotest.(check int) "exactly one submit" 1 (List.length decision.submit);
  let req = List.hd decision.submit in
  Alcotest.(check string) "submit quantity = total" "100" (Decimal.to_string req.quantity);
  Alcotest.(check (list int))
    "no cancels" []
    (List.map Placement.Values.Placement_id.to_int decision.cancel);
  match decision.terminal with
  | Decision.Continue -> ()
  | _ -> Alcotest.fail "initial decision should be Continue"

let test_full_fill_terminates_completed () =
  let intent = intent_buy_100 () in
  let state, _ = Imm.init ~intent ~now:1_700_000_000L in
  let _state', decision =
    Imm.on_event state
      (Input.Placement_filled
         {
           placement_id = placement_id_1;
           fill = fill ~quantity:"100" ~price:"250.00" ~fee:"0";
         })
      ~now:1_700_000_010L
  in
  Alcotest.(check int) "no new submit" 0 (List.length decision.submit);
  match decision.terminal with
  | Decision.Completed -> ()
  | _ -> Alcotest.fail "full fill should produce Completed terminal"

let test_partial_fill_stays_continuing () =
  let intent = intent_buy_100 () in
  let state, _ = Imm.init ~intent ~now:1_700_000_000L in
  let _state', decision =
    Imm.on_event state
      (Input.Placement_filled
         {
           placement_id = placement_id_1;
           fill = fill ~quantity:"40" ~price:"250.00" ~fee:"0";
         })
      ~now:1_700_000_010L
  in
  Alcotest.(check int) "no new submit on partial" 0 (List.length decision.submit);
  match decision.terminal with
  | Decision.Continue -> ()
  | _ -> Alcotest.fail "partial fill should keep Continue"

let test_rejection_terminates_failed () =
  let intent = intent_buy_100 () in
  let state, _ = Imm.init ~intent ~now:1_700_000_000L in
  let _state', decision =
    Imm.on_event state
      (Input.Placement_rejected
         { placement_id = placement_id_1; reason = "instrument suspended" })
      ~now:1_700_000_010L
  in
  match decision.terminal with
  | Decision.Failed reason ->
      Alcotest.(check bool) "reason carries broker message" true (String.length reason > 0)
  | _ -> Alcotest.fail "rejection should produce Failed terminal"

let test_unreachable_terminates_failed () =
  let intent = intent_buy_100 () in
  let state, _ = Imm.init ~intent ~now:1_700_000_000L in
  let _state', decision =
    Imm.on_event state
      (Input.Placement_unreachable { placement_id = placement_id_1 })
      ~now:1_700_000_010L
  in
  match decision.terminal with
  | Decision.Failed _ -> ()
  | _ -> Alcotest.fail "unreachable should produce Failed terminal"

let test_tick_is_ignored () =
  let intent = intent_buy_100 () in
  let state, _ = Imm.init ~intent ~now:1_700_000_000L in
  let _state', decision =
    Imm.on_event state (Input.Tick { now = 1_700_000_010L }) ~now:1_700_000_010L
  in
  Alcotest.(check int) "tick triggers no submit" 0 (List.length decision.submit);
  match decision.terminal with
  | Decision.Continue -> ()
  | _ -> Alcotest.fail "tick should not move the terminal state"

let test_terminal_state_absorbs_late_events () =
  let intent = intent_buy_100 () in
  let state, _ = Imm.init ~intent ~now:1_700_000_000L in
  let state', _ =
    Imm.on_event state
      (Input.Placement_filled
         {
           placement_id = placement_id_1;
           fill = fill ~quantity:"100" ~price:"250.00" ~fee:"0";
         })
      ~now:1_700_000_010L
  in
  Alcotest.(check bool) "complete after full fill" true (Imm.is_complete state');
  let _state'', decision =
    Imm.on_event state'
      (Input.Placement_rejected { placement_id = placement_id_1; reason = "late ack" })
      ~now:1_700_000_020L
  in
  Alcotest.(check int) "no work on late event" 0 (List.length decision.submit);
  match decision.terminal with
  | Decision.Continue -> ()
  | _ -> Alcotest.fail "late event in terminal state should yield Continue noop"

let test_strategy_dispatcher_via_immediate_directive () =
  let intent = intent_buy_100 () in
  let strategy, decision =
    Ot.Strategies.Strategy.init ~intent ~directive:Values.Execution_directive.Immediate
      ~now:1_700_000_000L
  in
  Alcotest.(check int)
    "init via dispatcher emits one submit" 1 (List.length decision.submit);
  Alcotest.(check bool)
    "not complete at init" false
    (Ot.Strategies.Strategy.is_complete strategy)

let tests =
  [
    Alcotest.test_case "init emits single submit with full quantity" `Quick
      test_init_emits_single_submit_with_full_quantity;
    Alcotest.test_case "full fill terminates Completed" `Quick
      test_full_fill_terminates_completed;
    Alcotest.test_case "partial fill keeps Continue" `Quick
      test_partial_fill_stays_continuing;
    Alcotest.test_case "rejection terminates Failed" `Quick
      test_rejection_terminates_failed;
    Alcotest.test_case "unreachable terminates Failed" `Quick
      test_unreachable_terminates_failed;
    Alcotest.test_case "Tick is ignored" `Quick test_tick_is_ignored;
    Alcotest.test_case "terminal state absorbs late events" `Quick
      test_terminal_state_absorbs_late_events;
    Alcotest.test_case "Strategy dispatcher via Immediate directive" `Quick
      test_strategy_dispatcher_via_immediate_directive;
  ]
