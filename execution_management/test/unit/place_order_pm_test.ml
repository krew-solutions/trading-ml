(** Unit tests for {!Execution_management_process_managers.Place_order_pm.Definition}.
    Drives the pure transition function across happy + compensation
    paths. No bus, no Eio. *)

module Pm = Execution_management_process_managers.Place_order_pm
module Inbound = Execution_management_external_integration_events

let cid = "saga-A"

let payload =
  Pm.initial_payload ~book_id:"alpha" ~symbol:"SBER@MISX" ~side:"BUY" ~quantity:"10"

let instrument_vm : Execution_management_external_view_models.Instrument_view_model.t =
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

let order_view : Execution_management_external_view_models.Order_view_model.t =
  {
    id = "o1";
    exec_id = "e1";
    client_order_id = "c1";
    instrument = instrument_vm;
    side = "BUY";
    quantity = "10";
    filled = "0";
    remaining = "10";
    kind = { type_ = "MARKET"; price = None; stop_price = None; limit_price = None };
    tif = "DAY";
    status = "NEW";
    created_ts = 0L;
  }

let order_accepted : Inbound.Order_accepted_integration_event.t =
  { correlation_id = cid; reservation_id = 42; broker_order = order_view }

let order_rejected : Inbound.Order_rejected_integration_event.t =
  { correlation_id = cid; reservation_id = 42; reason = "no liquidity" }

let order_unreachable : Inbound.Order_unreachable_integration_event.t =
  { correlation_id = cid; reservation_id = 42; reason = "timeout" }

let is_submit_for_42 = function
  | Pm.Dispatch_submit { reservation_id = 42; _ } -> true
  | _ -> false

let is_release_for_42 = function
  | Pm.Dispatch_release { reservation_id = 42; correlation_id = c } when c = cid -> true
  | _ -> false

let test_amount_reserved_emits_submit_and_advances () =
  let s0 = Pm.Awaiting_reservation { payload } in
  let s1, cmds = Pm.Definition.transition s0 (Pm.Amount_reserved amount_reserved) in
  (match s1 with
  | Submitted { reservation_id = 42; _ } -> ()
  | _ -> Alcotest.fail "expected Submitted");
  Alcotest.(check bool) "emits Submit" true (List.exists is_submit_for_42 cmds);
  Alcotest.(check int) "one command" 1 (List.length cmds)

let test_reservation_rejected_compensates_no_cmds () =
  let s0 = Pm.Awaiting_reservation { payload } in
  let s1, cmds =
    Pm.Definition.transition s0 (Pm.Reservation_rejected reservation_rejected)
  in
  (match s1 with
  | Compensated _ -> ()
  | _ -> Alcotest.fail "expected Compensated");
  Alcotest.(check int) "no cmds" 0 (List.length cmds)

let test_order_accepted_terminal_no_cmds () =
  let s0 = Pm.Submitted { payload; reservation_id = 42 } in
  let s1, cmds = Pm.Definition.transition s0 (Pm.Order_accepted order_accepted) in
  (match s1 with
  | Done { reservation_id = 42 } -> ()
  | _ -> Alcotest.fail "expected Done");
  Alcotest.(check int) "no cmds" 0 (List.length cmds)

let test_order_rejected_releases_and_compensates () =
  let s0 = Pm.Submitted { payload; reservation_id = 42 } in
  let s1, cmds = Pm.Definition.transition s0 (Pm.Order_rejected order_rejected) in
  (match s1 with
  | Compensated _ -> ()
  | _ -> Alcotest.fail "expected Compensated");
  Alcotest.(check bool) "emits Release" true (List.exists is_release_for_42 cmds)

let test_order_unreachable_releases_and_compensates () =
  let s0 = Pm.Submitted { payload; reservation_id = 42 } in
  let s1, cmds = Pm.Definition.transition s0 (Pm.Order_unreachable order_unreachable) in
  (match s1 with
  | Compensated _ -> ()
  | _ -> Alcotest.fail "expected Compensated");
  Alcotest.(check bool) "emits Release" true (List.exists is_release_for_42 cmds)

let test_late_event_in_done_is_noop () =
  let s0 = Pm.Done { reservation_id = 42 } in
  let s1, cmds = Pm.Definition.transition s0 (Pm.Order_accepted order_accepted) in
  Alcotest.(check int) "no cmds" 0 (List.length cmds);
  match s1 with
  | Done { reservation_id = 42 } -> ()
  | _ -> Alcotest.fail "state unchanged"

let test_late_amount_reserved_in_submitted_is_noop () =
  let s0 = Pm.Submitted { payload; reservation_id = 42 } in
  let s1, cmds = Pm.Definition.transition s0 (Pm.Amount_reserved amount_reserved) in
  Alcotest.(check int) "no cmds" 0 (List.length cmds);
  match s1 with
  | Submitted { reservation_id = 42; _ } -> ()
  | _ -> Alcotest.fail "state unchanged"

let tests =
  [
    Alcotest.test_case "Amount_reserved emits Submit and advances" `Quick
      test_amount_reserved_emits_submit_and_advances;
    Alcotest.test_case "Reservation_rejected compensates no cmds" `Quick
      test_reservation_rejected_compensates_no_cmds;
    Alcotest.test_case "Order_accepted terminal no cmds" `Quick
      test_order_accepted_terminal_no_cmds;
    Alcotest.test_case "Order_rejected releases and compensates" `Quick
      test_order_rejected_releases_and_compensates;
    Alcotest.test_case "Order_unreachable releases and compensates" `Quick
      test_order_unreachable_releases_and_compensates;
    Alcotest.test_case "Late event in Done is noop" `Quick test_late_event_in_done_is_noop;
    Alcotest.test_case "Late Amount_reserved in Submitted is noop" `Quick
      test_late_amount_reserved_in_submitted_is_noop;
  ]
