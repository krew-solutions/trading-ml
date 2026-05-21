(** Unit tests for {!Order_management_process_managers.Order_process_manager.Definition}.

    The saga now owns the full reservation-cycle lifecycle:
    Awaiting_reservation → Working → {Settled | Released} via
    the OrderTicket lifecycle events from EM. *)

module Pm = Order_management_process_managers.Order_process_manager
module Inbound = Order_management_external_integration_events

let cid = "saga-A"

let payload =
  Pm.initial_payload ~book_id:"alpha" ~symbol:"SBER@MISX" ~side:"BUY" ~quantity:"10" ()

let instrument_vm : Order_management_external_view_models.Instrument_view_model.t =
  { ticker = "SBER"; venue = "MISX"; isin = None; board = None }

let amount_reserved : Inbound.Amount_reserved_integration_event.t =
  {
    correlation_id = cid;
    reservation_id = 42;
    side = "BUY";
    instrument = instrument_vm;
    quantity = "10";
    price = "100";
    reserved_cash = "1000";
  }

let reservation_rejected : Inbound.Reservation_rejected_integration_event.t =
  {
    correlation_id = cid;
    side = "BUY";
    instrument = instrument_vm;
    quantity = "10";
    reason = "insufficient cash";
  }

let progress_zero : Order_management_external_view_models.Progress_view_model.t =
  {
    total_quantity = "10";
    cumulative_filled = "0";
    remaining_quantity = "10";
    total_fees = "0";
  }

let progress_full : Order_management_external_view_models.Progress_view_model.t =
  {
    total_quantity = "10";
    cumulative_filled = "10";
    remaining_quantity = "0";
    total_fees = "0.05";
  }

let fill_recorded : Inbound.Order_ticket_fill_recorded_integration_event.t =
  {
    correlation_id = cid;
    ticket_id = 42;
    reservation_id = 42;
    fill_quantity = "10";
    fill_price = "100";
    fee = "0.05";
    occurred_at = "1970-01-01T00:00:00Z";
  }

let ticket_completed : Inbound.Order_ticket_completed_integration_event.t =
  {
    correlation_id = cid;
    ticket_id = 42;
    reservation_id = 42;
    progress = progress_full;
    occurred_at = "1970-01-01T00:00:00Z";
  }

let ticket_cancelled : Inbound.Order_ticket_cancelled_integration_event.t =
  {
    correlation_id = cid;
    ticket_id = 42;
    reservation_id = 42;
    reason = "operator";
    progress = progress_zero;
    occurred_at = "1970-01-01T00:00:00Z";
  }

let ticket_failed : Inbound.Order_ticket_failed_integration_event.t =
  {
    correlation_id = cid;
    ticket_id = 42;
    reservation_id = 42;
    reason = "venue down";
    progress = progress_zero;
    occurred_at = "1970-01-01T00:00:00Z";
  }

let is_dispatch_open_ticket_for_42 = function
  | Pm.Dispatch_open_ticket { reservation_id = 42; _ } -> true
  | _ -> false

let is_commit_fill = function
  | Pm.Dispatch_commit_fill _ -> true
  | _ -> false

let is_release = function
  | Pm.Dispatch_release _ -> true
  | _ -> false

let test_amount_reserved_advances_to_working () =
  let s0 = Pm.Awaiting_reservation { payload } in
  let s1, cmds = Pm.Definition.transition s0 (Pm.Amount_reserved amount_reserved) in
  (match s1 with
  | Working { reservation_id = 42; _ } -> ()
  | _ -> Alcotest.fail "expected Working");
  Alcotest.(check bool)
    "emits Dispatch_open_ticket" true
    (List.exists is_dispatch_open_ticket_for_42 cmds);
  Alcotest.(check int) "exactly one command" 1 (List.length cmds)

let test_reservation_rejected_compensates () =
  let s0 = Pm.Awaiting_reservation { payload } in
  let s1, cmds =
    Pm.Definition.transition s0 (Pm.Reservation_rejected reservation_rejected)
  in
  (match s1 with
  | Compensated _ -> ()
  | _ -> Alcotest.fail "expected Compensated");
  Alcotest.(check int) "no cmds" 0 (List.length cmds)

let test_fill_in_working_emits_commit_fill () =
  let s0 = Pm.Working { reservation_id = 42; correlation_id = cid } in
  let s1, cmds = Pm.Definition.transition s0 (Pm.Ticket_fill_recorded fill_recorded) in
  Alcotest.(check bool)
    "stays in Working" true
    (match s1 with
    | Pm.Working _ -> true
    | _ -> false);
  Alcotest.(check int) "exactly one command" 1 (List.length cmds);
  Alcotest.(check bool) "command is Commit_fill" true (List.exists is_commit_fill cmds)

let test_ticket_completed_settles_with_no_command () =
  let s0 = Pm.Working { reservation_id = 42; correlation_id = cid } in
  let s1, cmds = Pm.Definition.transition s0 (Pm.Ticket_completed ticket_completed) in
  Alcotest.(check bool)
    "transitions to Settled" true
    (match s1 with
    | Pm.Settled { reservation_id = 42 } -> true
    | _ -> false);
  Alcotest.(check int) "no command emitted" 0 (List.length cmds)

let test_ticket_cancelled_releases () =
  let s0 = Pm.Working { reservation_id = 42; correlation_id = cid } in
  let s1, cmds = Pm.Definition.transition s0 (Pm.Ticket_cancelled ticket_cancelled) in
  Alcotest.(check bool)
    "transitions to Released" true
    (match s1 with
    | Pm.Released { reservation_id = 42; _ } -> true
    | _ -> false);
  Alcotest.(check int) "one command emitted" 1 (List.length cmds);
  Alcotest.(check bool) "command is Release" true (List.exists is_release cmds)

let test_ticket_failed_releases () =
  let s0 = Pm.Working { reservation_id = 42; correlation_id = cid } in
  let s1, cmds = Pm.Definition.transition s0 (Pm.Ticket_failed ticket_failed) in
  Alcotest.(check bool)
    "transitions to Released" true
    (match s1 with
    | Pm.Released { reservation_id = 42; _ } -> true
    | _ -> false);
  Alcotest.(check int) "one command emitted" 1 (List.length cmds);
  Alcotest.(check bool) "command is Release" true (List.exists is_release cmds)

let test_late_event_in_settled_is_noop () =
  let s0 = Pm.Settled { reservation_id = 42 } in
  let s1, cmds = Pm.Definition.transition s0 (Pm.Ticket_fill_recorded fill_recorded) in
  Alcotest.(check int) "no cmds" 0 (List.length cmds);
  match s1 with
  | Settled { reservation_id = 42 } -> ()
  | _ -> Alcotest.fail "state unchanged"

let test_late_event_in_compensated_is_noop () =
  let s0 = Pm.Compensated { reason = "rejected_by_account: x" } in
  let s1, cmds =
    Pm.Definition.transition s0 (Pm.Reservation_rejected reservation_rejected)
  in
  Alcotest.(check int) "no cmds" 0 (List.length cmds);
  match s1 with
  | Compensated _ -> ()
  | _ -> Alcotest.fail "state unchanged"

let tests =
  [
    Alcotest.test_case "Amount_reserved → Working + Dispatch_open_ticket" `Quick
      test_amount_reserved_advances_to_working;
    Alcotest.test_case "Reservation_rejected → Compensated, no cmds" `Quick
      test_reservation_rejected_compensates;
    Alcotest.test_case "Ticket_fill_recorded in Working → Commit_fill" `Quick
      test_fill_in_working_emits_commit_fill;
    Alcotest.test_case "Ticket_completed → Settled (no command)" `Quick
      test_ticket_completed_settles_with_no_command;
    Alcotest.test_case "Ticket_cancelled → Released + Dispatch_release" `Quick
      test_ticket_cancelled_releases;
    Alcotest.test_case "Ticket_failed → Released + Dispatch_release" `Quick
      test_ticket_failed_releases;
    Alcotest.test_case "Late Ticket_fill_recorded in Settled is noop" `Quick
      test_late_event_in_settled_is_noop;
    Alcotest.test_case "Late event in Compensated is noop" `Quick
      test_late_event_in_compensated_is_noop;
  ]
