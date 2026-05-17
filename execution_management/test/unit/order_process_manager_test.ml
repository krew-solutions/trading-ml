(** Unit tests for {!Execution_management_process_managers.Order_process_manager.Definition}.
    Drives the pure transition function across reservation
    happy + compensation paths. The saga's responsibility is
    narrow: reserve cash and hand off to the OrderTicket
    aggregate; broker-leg lifecycle is the aggregate's concern
    and is exercised in [order_ticket_test.ml] and the BDD
    scenarios. *)

module Pm = Execution_management_process_managers.Order_process_manager
module Inbound = Execution_management_external_integration_events

let cid = "saga-A"

let payload =
  Pm.initial_payload ~book_id:"alpha" ~symbol:"SBER@MISX" ~side:"BUY"
    ~quantity:"10" ()

let instrument_vm : Execution_management_external_view_models.Instrument_view_model.t
    =
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

let is_dispatch_open_ticket_for_42 = function
  | Pm.Dispatch_open_ticket { reservation_id = 42; _ } -> true
  | _ -> false

let test_amount_reserved_advances_to_done_and_emits_open_ticket () =
  let s0 = Pm.Awaiting_reservation { payload } in
  let s1, cmds = Pm.Definition.transition s0 (Pm.Amount_reserved amount_reserved) in
  (match s1 with
  | Done { reservation_id = 42 } -> ()
  | _ -> Alcotest.fail "expected Done");
  Alcotest.(check bool)
    "emits Dispatch_open_ticket" true
    (List.exists is_dispatch_open_ticket_for_42 cmds);
  Alcotest.(check int) "exactly one command" 1 (List.length cmds)

let test_reservation_rejected_compensates_no_cmds () =
  let s0 = Pm.Awaiting_reservation { payload } in
  let s1, cmds =
    Pm.Definition.transition s0 (Pm.Reservation_rejected reservation_rejected)
  in
  (match s1 with
  | Compensated _ -> ()
  | _ -> Alcotest.fail "expected Compensated");
  Alcotest.(check int) "no cmds" 0 (List.length cmds)

let test_late_amount_reserved_in_done_is_noop () =
  let s0 = Pm.Done { reservation_id = 42 } in
  let s1, cmds = Pm.Definition.transition s0 (Pm.Amount_reserved amount_reserved) in
  Alcotest.(check int) "no cmds" 0 (List.length cmds);
  match s1 with
  | Done { reservation_id = 42 } -> ()
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
    Alcotest.test_case
      "Amount_reserved → Done + Dispatch_open_ticket emitted" `Quick
      test_amount_reserved_advances_to_done_and_emits_open_ticket;
    Alcotest.test_case "Reservation_rejected → Compensated, no cmds" `Quick
      test_reservation_rejected_compensates_no_cmds;
    Alcotest.test_case "Late Amount_reserved in Done is noop" `Quick
      test_late_amount_reserved_in_done_is_noop;
    Alcotest.test_case "Late event in Compensated is noop" `Quick
      test_late_event_in_compensated_is_noop;
  ]
