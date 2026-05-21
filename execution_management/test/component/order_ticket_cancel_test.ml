(** BDD scenarios for the operator-cancel path on an Immediate
    ticket. Drives the cancel_order_ticket and
    apply_placement_cancelled command workflows end-to-end against
    an in-memory ticket_store and a recording publish callback. *)

module Gherkin = Gherkin_edsl
module Ot = Execution_management.Order_ticket
open Order_ticket_harness

let ticket_id = 42

let operator_cancel_before_any_fill =
  Gherkin.scenario "An operator cancels a working ticket before any fill arrives"
    fresh_ctx
    [
      Gherkin.given "an Immediate ticket has been opened" (fun ctx ->
          open_immediate_ticket ctx ~ticket_id ~correlation_id:"saga-cancel-A");
      Gherkin.when_ "the operator issues a cancel" (fun ctx ->
          cancel_ticket ctx ~ticket_id ~reason:"operator");
      Gherkin.then_
        "the ticket announces it is cancelling and broker-side cancels are emitted"
        (fun ctx ->
          let evs = emitted ctx in
          Alcotest.(check int)
            "one Ticket_cancelling_started" 1
            (count_kind is_cancelling_started evs);
          match lifecycle ctx ~ticket_id with
          | Cancelling _ -> ()
          | _ -> Alcotest.fail "expected Cancelling lifecycle");
      Gherkin.when_ "the broker confirms every outstanding placement was cancelled"
        (fun ctx ->
          let pids = outstanding_after_open ctx ~ticket_id in
          List.fold_left
            (fun ctx pid ->
              apply_placement_cancelled ctx ~ticket_id
                ~placement_id:(Ot.Placement.Values.Placement_id.to_int pid))
            ctx pids);
      Gherkin.then_ "the ticket reaches the Cancelled terminal state and announces it"
        (fun ctx ->
          let evs = emitted ctx in
          Alcotest.(check int)
            "exactly one Ticket_cancelled emitted" 1
            (count_kind is_ticket_cancelled evs);
          match lifecycle ctx ~ticket_id with
          | Cancelled _ -> ()
          | _ -> Alcotest.fail "expected Cancelled terminal");
    ]

let cancel_after_full_fill_is_a_noop =
  Gherkin.scenario
    "A cancel arriving after the ticket already filled completely is absorbed" fresh_ctx
    [
      Gherkin.given "an Immediate ticket has been opened and fully filled" (fun ctx ->
          let ctx =
            open_immediate_ticket ctx ~ticket_id ~correlation_id:"saga-cancel-B"
          in
          let pid =
            match outstanding_after_open ctx ~ticket_id with
            | [ pid ] -> Ot.Placement.Values.Placement_id.to_int pid
            | _ -> Alcotest.fail "expected exactly one placement after open"
          in
          apply_placement_fill ctx ~ticket_id ~placement_id:pid ~quantity:"100");
      Gherkin.when_ "the operator issues a cancel anyway" (fun ctx ->
          cancel_ticket ctx ~ticket_id ~reason:"operator");
      Gherkin.then_
        "the cancel produces no extra cancelling event and the ticket stays Filled"
        (fun ctx ->
          let evs = emitted ctx in
          Alcotest.(check int)
            "no Ticket_cancelling_started" 0
            (count_kind is_cancelling_started evs);
          Alcotest.(check int)
            "one Ticket_completed remains" 1
            (count_kind is_ticket_completed evs);
          match lifecycle ctx ~ticket_id with
          | Filled -> ()
          | _ -> Alcotest.fail "expected Filled lifecycle");
    ]

let placement_id_of_terminal_ticket ctx =
  match ticket ctx ~ticket_id with
  | Some t -> (
      match Ot.placements t with
      | (p : Ot.Placement.t) :: _ -> Ot.Placement.Values.Placement_id.to_int p.id
      | [] -> Alcotest.fail "no placements on cancelled ticket")
  | None -> Alcotest.fail "ticket vanished from store"

let late_placement_cancelled_in_terminal_is_dropped =
  Gherkin.scenario
    "A late broker Order_cancelled for an already-terminal ticket is silently dropped"
    fresh_ctx
    [
      Gherkin.given "an Immediate ticket cancelled to terminal" (fun ctx ->
          let ctx =
            open_immediate_ticket ctx ~ticket_id ~correlation_id:"saga-cancel-C"
          in
          let ctx = cancel_ticket ctx ~ticket_id ~reason:"operator" in
          let pids = outstanding_after_open ctx ~ticket_id in
          List.fold_left
            (fun ctx pid ->
              apply_placement_cancelled ctx ~ticket_id
                ~placement_id:(Ot.Placement.Values.Placement_id.to_int pid))
            ctx pids);
      Gherkin.when_ "a late broker Order_cancelled arrives for the same placement"
        (fun ctx ->
          let pid = placement_id_of_terminal_ticket ctx in
          apply_placement_cancelled ctx ~ticket_id ~placement_id:pid);
      Gherkin.then_ "no new Ticket_cancelled is emitted" (fun ctx ->
          let evs = emitted ctx in
          Alcotest.(check int)
            "still exactly one Ticket_cancelled" 1
            (count_kind is_ticket_cancelled evs));
    ]

let feature =
  Gherkin.feature "Order_ticket operator cancel"
    [
      operator_cancel_before_any_fill;
      cancel_after_full_fill_is_a_noop;
      late_placement_cancelled_in_terminal_is_dropped;
    ]
