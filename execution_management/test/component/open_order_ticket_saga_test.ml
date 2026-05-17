(** BDD specification for the Open_order_ticket saga.

    The saga's narrowed responsibility (per ADR-0017): take an
    approved trade intent, dispatch a Reserve to Account, and on
    response either (a) hand off to the EMS-side OrderTicket
    aggregate via an in-process Dispatch_open_ticket, or (b)
    transition to Compensated when Account refuses. Broker-leg
    lifecycle (placement dispatch, fills, rejections, cancels)
    is OrderTicket's concern — see order_ticket_e2e_test.ml. *)

module Gherkin = Gherkin_edsl
module Pm = Execution_management_process_managers.Open_order_ticket_process
open Test_harness

let cid = "saga-component-A"

let is_reserve = function
  | Pm.Dispatch_reserve _ -> true
  | _ -> false

let is_open_ticket = function
  | Pm.Dispatch_open_ticket _ -> true
  | _ -> false

let count p l = List.length (List.filter p l)

let happy_path =
  Gherkin.scenario
    "An approved trade reserves and then hands off to the OrderTicket aggregate"
    fresh_ctx
    [
      Gherkin.given "a fresh saga engine" (fun ctx -> ctx);
      Gherkin.when_ "the saga starts for an approved trade" (fun ctx ->
          ctx
          |> start_saga ~correlation_id:cid ~book_id:"alpha" ~symbol:"SBER@MISX"
               ~side:"BUY" ~quantity:"10" ~price:"100");
      Gherkin.then_ "a Reserve command is dispatched immediately" (fun ctx ->
          let cmds = dispatched_commands ctx in
          Alcotest.(check int) "one Reserve" 1 (count is_reserve cmds);
          Alcotest.(check int) "no Dispatch_open_ticket yet" 0
            (count is_open_ticket cmds));
      Gherkin.when_ "the account announces the reservation succeeded" (fun ctx ->
          ctx
          |> push_amount_reserved ~correlation_id:cid ~reservation_id:42
               ~symbol:"SBER@MISX" ~side:"BUY" ~quantity:"10" ~price:"100"
               ~reserved_cash:"1000");
      Gherkin.then_ "the saga dispatches Dispatch_open_ticket and reaches Done"
        (fun ctx ->
          let cmds = dispatched_commands ctx in
          Alcotest.(check int) "one Dispatch_open_ticket" 1
            (count is_open_ticket cmds);
          match saga_state ctx ~correlation_id:cid with
          | None -> ()
          | Some _ -> Alcotest.fail "expected the terminal saga to be dropped");
    ]

let reservation_rejected_compensates =
  Gherkin.scenario
    "When the account refuses the reservation the saga compensates without further action"
    fresh_ctx
    [
      Gherkin.given "a fresh saga engine and a started saga" (fun ctx ->
          ctx
          |> start_saga ~correlation_id:cid ~book_id:"alpha" ~symbol:"SBER@MISX"
               ~side:"BUY" ~quantity:"10" ~price:"100");
      Gherkin.when_ "the account announces a reservation rejection" (fun ctx ->
          ctx
          |> push_reservation_rejected ~correlation_id:cid ~symbol:"SBER@MISX"
               ~side:"BUY" ~quantity:"10" ~reason:"insufficient cash");
      Gherkin.then_ "the saga reaches Compensated and is dropped" (fun ctx ->
          Alcotest.(check int) "no active sagas" 0 (active_count ctx));
      Gherkin.then_
        "no Dispatch_open_ticket is issued — nothing to hand off" (fun ctx ->
          Alcotest.(check int)
            "open_ticket count" 0
            (count is_open_ticket (dispatched_commands ctx)));
    ]

let event_for_terminated_saga_is_silently_dropped =
  Gherkin.scenario
    "An event arriving after the saga has reached Done is silently dropped"
    fresh_ctx
    [
      Gherkin.given "a saga that already reached Done" (fun ctx ->
          ctx
          |> start_saga ~correlation_id:cid ~book_id:"alpha" ~symbol:"SBER@MISX"
               ~side:"BUY" ~quantity:"10" ~price:"100"
          |> push_amount_reserved ~correlation_id:cid ~reservation_id:42
               ~symbol:"SBER@MISX" ~side:"BUY" ~quantity:"10" ~price:"100"
               ~reserved_cash:"1000");
      Gherkin.when_ "a late Amount_reserved with the same correlation_id arrives"
        (fun ctx ->
          ctx
          |> push_amount_reserved ~correlation_id:cid ~reservation_id:42
               ~symbol:"SBER@MISX" ~side:"BUY" ~quantity:"10" ~price:"100"
               ~reserved_cash:"1000");
      Gherkin.then_ "no extra dispatch is produced" (fun ctx ->
          Alcotest.(check int)
            "open_ticket count" 1
            (count is_open_ticket (dispatched_commands ctx)));
      Gherkin.then_ "no saga instance is resurrected" (fun ctx ->
          Alcotest.(check int) "active count" 0 (active_count ctx));
    ]

let unrelated_correlation_id_does_not_advance_other_sagas =
  Gherkin.scenario
    "An event for an unknown correlation_id does not affect any running saga"
    fresh_ctx
    [
      Gherkin.given "a saga running for cid \"saga-A\"" (fun ctx ->
          ctx
          |> start_saga ~correlation_id:"saga-A" ~book_id:"alpha"
               ~symbol:"SBER@MISX" ~side:"BUY" ~quantity:"10" ~price:"100");
      Gherkin.when_
        "an Amount_reserved arrives for a different cid \"saga-B\"" (fun ctx ->
          ctx
          |> push_amount_reserved ~correlation_id:"saga-B" ~reservation_id:42
               ~symbol:"SBER@MISX" ~side:"BUY" ~quantity:"10" ~price:"100"
               ~reserved_cash:"1000");
      Gherkin.then_ "saga-A is still in Awaiting_reservation" (fun ctx ->
          match saga_state ctx ~correlation_id:"saga-A" with
          | Some (Pm.Awaiting_reservation _) -> ()
          | _ -> Alcotest.fail "expected saga-A in Awaiting_reservation");
      Gherkin.then_ "no Dispatch_open_ticket for saga-A" (fun ctx ->
          (* saga-B's event reached its own (uninitiated) saga which
             ignores the event since no instance exists for it. *)
          let cmds = dispatched_commands ctx in
          Alcotest.(check int)
            "open_ticket count" 0
            (count is_open_ticket cmds));
    ]

let feature =
  Gherkin.feature "Open_order_ticket saga"
    [
      happy_path;
      reservation_rejected_compensates;
      event_for_terminated_saga_is_silently_dropped;
      unrelated_correlation_id_does_not_advance_other_sagas;
    ]
