(** BDD specification for the Order_process_manager saga.

    The saga owns the full reservation-cycle lifecycle:
    Awaiting_reservation → Working → {Settled | Released | Compensated}.
    Per-fill it dispatches Commit_fill_command; on terminal
    cancellation / failure it dispatches Release_command. *)

module Gherkin = Gherkin_edsl
module Pm = Order_management_process_managers.Order_process_manager
open Test_harness

let cid = "saga-component-A"

let is_reserve = function
  | Pm.Dispatch_reserve _ -> true
  | _ -> false
let is_open_ticket = function
  | Pm.Dispatch_open_ticket _ -> true
  | _ -> false
let is_commit_fill = function
  | Pm.Dispatch_commit_fill _ -> true
  | _ -> false
let is_release = function
  | Pm.Dispatch_release _ -> true
  | _ -> false

let count p l = List.length (List.filter p l)

let happy_path =
  Gherkin.scenario
    "Reservation lands, ticket opens, fills commit, ticket completes — saga settles"
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
          Alcotest.(check int) "no Dispatch_open_ticket yet" 0 (count is_open_ticket cmds));
      Gherkin.when_ "the account confirms the reservation" (fun ctx ->
          ctx
          |> push_amount_reserved ~correlation_id:cid ~reservation_id:42
               ~symbol:"SBER@MISX" ~side:"BUY" ~quantity:"10" ~price:"100"
               ~reserved_cash:"1000");
      Gherkin.then_ "Dispatch_open_ticket is emitted and the saga sits in Working"
        (fun ctx ->
          let cmds = dispatched_commands ctx in
          Alcotest.(check int) "one Dispatch_open_ticket" 1 (count is_open_ticket cmds);
          match saga_state ctx ~correlation_id:cid with
          | Some (Pm.Working _) -> ()
          | _ -> Alcotest.fail "expected Working");
      Gherkin.when_ "a fill is observed on the ticket" (fun ctx ->
          ctx
          |> push_ticket_fill_recorded ~correlation_id:cid ~ticket_id:42
               ~reservation_id:42 ~quantity:"10" ~price:"100" ~fee:"0.05");
      Gherkin.then_ "Commit_fill_command is dispatched to Account" (fun ctx ->
          Alcotest.(check int)
            "one Commit_fill" 1
            (count is_commit_fill (dispatched_commands ctx)));
      Gherkin.when_ "the ticket announces it completed" (fun ctx ->
          ctx
          |> push_ticket_completed ~correlation_id:cid ~ticket_id:42 ~reservation_id:42);
      Gherkin.then_ "the saga reaches the Settled terminal and is dropped" (fun ctx ->
          Alcotest.(check int) "no active sagas" 0 (active_count ctx);
          Alcotest.(check int)
            "no Release emitted" 0
            (count is_release (dispatched_commands ctx)));
    ]

let cancelled_path =
  Gherkin.scenario "A working ticket gets cancelled — saga releases the reservation"
    fresh_ctx
    [
      Gherkin.given "a saga in Working state" (fun ctx ->
          ctx
          |> start_saga ~correlation_id:cid ~book_id:"alpha" ~symbol:"SBER@MISX"
               ~side:"BUY" ~quantity:"10" ~price:"100"
          |> push_amount_reserved ~correlation_id:cid ~reservation_id:42
               ~symbol:"SBER@MISX" ~side:"BUY" ~quantity:"10" ~price:"100"
               ~reserved_cash:"1000");
      Gherkin.when_ "the ticket is cancelled" (fun ctx ->
          ctx
          |> push_ticket_cancelled ~correlation_id:cid ~ticket_id:42 ~reservation_id:42
               ~reason:"operator");
      Gherkin.then_ "Release_command is dispatched and the saga reaches Released"
        (fun ctx ->
          Alcotest.(check int)
            "one Release" 1
            (count is_release (dispatched_commands ctx));
          Alcotest.(check int) "saga dropped" 0 (active_count ctx));
    ]

let failed_path =
  Gherkin.scenario "A working ticket fails — saga releases the reservation" fresh_ctx
    [
      Gherkin.given "a saga in Working state" (fun ctx ->
          ctx
          |> start_saga ~correlation_id:cid ~book_id:"alpha" ~symbol:"SBER@MISX"
               ~side:"BUY" ~quantity:"10" ~price:"100"
          |> push_amount_reserved ~correlation_id:cid ~reservation_id:42
               ~symbol:"SBER@MISX" ~side:"BUY" ~quantity:"10" ~price:"100"
               ~reserved_cash:"1000");
      Gherkin.when_ "the ticket fails" (fun ctx ->
          ctx
          |> push_ticket_failed ~correlation_id:cid ~ticket_id:42 ~reservation_id:42
               ~reason:"venue down");
      Gherkin.then_ "Release_command is dispatched and the saga reaches Released"
        (fun ctx ->
          Alcotest.(check int)
            "one Release" 1
            (count is_release (dispatched_commands ctx));
          Alcotest.(check int) "saga dropped" 0 (active_count ctx));
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
          |> push_reservation_rejected ~correlation_id:cid ~symbol:"SBER@MISX" ~side:"BUY"
               ~quantity:"10" ~reason:"insufficient cash");
      Gherkin.then_ "the saga reaches Compensated and is dropped" (fun ctx ->
          Alcotest.(check int) "no active sagas" 0 (active_count ctx));
      Gherkin.then_ "no Dispatch_open_ticket is issued — nothing to hand off" (fun ctx ->
          Alcotest.(check int)
            "open_ticket count" 0
            (count is_open_ticket (dispatched_commands ctx)));
    ]

let late_event_in_settled_is_dropped =
  Gherkin.scenario
    "An event arriving after the saga has reached Settled is silently dropped" fresh_ctx
    [
      Gherkin.given "a saga that already reached Settled" (fun ctx ->
          ctx
          |> start_saga ~correlation_id:cid ~book_id:"alpha" ~symbol:"SBER@MISX"
               ~side:"BUY" ~quantity:"10" ~price:"100"
          |> push_amount_reserved ~correlation_id:cid ~reservation_id:42
               ~symbol:"SBER@MISX" ~side:"BUY" ~quantity:"10" ~price:"100"
               ~reserved_cash:"1000"
          |> push_ticket_completed ~correlation_id:cid ~ticket_id:42 ~reservation_id:42);
      Gherkin.when_ "a late Ticket_fill_recorded arrives for the same cid" (fun ctx ->
          ctx
          |> push_ticket_fill_recorded ~correlation_id:cid ~ticket_id:42
               ~reservation_id:42 ~quantity:"10" ~price:"100" ~fee:"0.05");
      Gherkin.then_ "no extra command is dispatched" (fun ctx ->
          Alcotest.(check int)
            "Commit_fill count stays 0" 0
            (count is_commit_fill (dispatched_commands ctx)));
      Gherkin.then_ "no saga instance is resurrected" (fun ctx ->
          Alcotest.(check int) "active count" 0 (active_count ctx));
    ]

let unrelated_correlation_id_does_not_advance_other_sagas =
  Gherkin.scenario
    "An event for an unknown correlation_id does not affect any running saga" fresh_ctx
    [
      Gherkin.given "a saga running for cid \"saga-A\"" (fun ctx ->
          ctx
          |> start_saga ~correlation_id:"saga-A" ~book_id:"alpha" ~symbol:"SBER@MISX"
               ~side:"BUY" ~quantity:"10" ~price:"100");
      Gherkin.when_ "an Amount_reserved arrives for a different cid \"saga-B\""
        (fun ctx ->
          ctx
          |> push_amount_reserved ~correlation_id:"saga-B" ~reservation_id:42
               ~symbol:"SBER@MISX" ~side:"BUY" ~quantity:"10" ~price:"100"
               ~reserved_cash:"1000");
      Gherkin.then_ "saga-A is still in Awaiting_reservation" (fun ctx ->
          match saga_state ctx ~correlation_id:"saga-A" with
          | Some (Pm.Awaiting_reservation _) -> ()
          | _ -> Alcotest.fail "expected saga-A in Awaiting_reservation");
      Gherkin.then_ "no Dispatch_open_ticket for saga-A" (fun ctx ->
          let cmds = dispatched_commands ctx in
          Alcotest.(check int) "open_ticket count" 0 (count is_open_ticket cmds));
    ]

let feature =
  Gherkin.feature "Order_process_manager saga"
    [
      happy_path;
      cancelled_path;
      failed_path;
      reservation_rejected_compensates;
      late_event_in_settled_is_dropped;
      unrelated_correlation_id_does_not_advance_other_sagas;
    ]
