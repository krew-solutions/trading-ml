module Inbound = Order_management_external_integration_events

type directive_payload = { directive_kind : string; directive_params : string option }

type payload = {
  book_id : string;
  symbol : string;
  side : string;
  quantity : string;
  kind_type : string;
  kind_price : string option;
  kind_stop_price : string option;
  kind_limit_price : string option;
  tif : string;
  directive : directive_payload option;
}

type working_state = { reservation_id : int; correlation_id : string }

type state =
  | Awaiting_reservation of { payload : payload }
  | Working of working_state
      (** Reservation confirmed, ticket dispatched to EM. Stays here
          while the OrderTicket executes; on the single
          Ticket_fill_recorded it dispatches one Commit_fill_command
          and waits for Account's Reservation_filled to reach
          Settled. Released instead on Ticket_cancelled /
          Ticket_failed (emits Release_command). *)
  | Settled of { reservation_id : int }
      (** Terminal: the single commit drew the reservation to zero,
          confirmed by Account's Reservation_filled. Nothing left to
          release. *)
  | Released of { reservation_id : int; reason : string }
      (** Terminal: ticket cancelled or failed. Release_command
          dispatched. *)
  | Compensated of { reason : string }
      (** Terminal: reservation never created (Account refused). *)

type event =
  | Amount_reserved of Inbound.Amount_reserved_integration_event.t
  | Reservation_rejected of Inbound.Reservation_rejected_integration_event.t
  | Ticket_fill_recorded of Inbound.Order_ticket_fill_recorded_integration_event.t
  | Reservation_filled of Inbound.Reservation_filled_integration_event.t
  | Ticket_cancelled of Inbound.Order_ticket_cancelled_integration_event.t
  | Ticket_failed of Inbound.Order_ticket_failed_integration_event.t

type command =
  | Dispatch_reserve of {
      correlation_id : string;
      side : string;
      symbol : string;
      quantity : string;
      price : string;
    }
  | Dispatch_open_ticket of {
      reservation_id : int;
      correlation_id : string;
      book_id : string;
      symbol : string;
      side : string;
      quantity : string;
      directive : directive_payload option;
    }
  | Dispatch_commit_fill of {
      correlation_id : string;
      reservation_id : int;
      quantity : string;
      price : string;
      fee : string;
    }
  | Dispatch_release of { correlation_id : string; reservation_id : int }

let initial_payload ?directive ~book_id ~symbol ~side ~quantity () =
  {
    book_id;
    symbol;
    side;
    quantity;
    kind_type = "MARKET";
    kind_price = None;
    kind_stop_price = None;
    kind_limit_price = None;
    tif = "DAY";
    directive;
  }

let reserve_for_start ~correlation_id ~(payload : payload) ~price =
  Dispatch_reserve
    {
      correlation_id;
      side = payload.side;
      symbol = payload.symbol;
      quantity = payload.quantity;
      price;
    }

module Definition = struct
  type nonrec state = state
  type nonrec event = event
  type nonrec command = command

  let name = "order_process_manager"

  let correlation_of_event = function
    | Amount_reserved e -> e.correlation_id
    | Reservation_rejected e -> e.correlation_id
    | Ticket_fill_recorded e -> e.correlation_id
    | Reservation_filled e -> e.correlation_id
    | Ticket_cancelled e -> e.correlation_id
    | Ticket_failed e -> e.correlation_id

  let transition (s : state) (e : event) : state * command list =
    match (s, e) with
    (* ---------- Awaiting_reservation ---------- *)
    | Awaiting_reservation { payload }, Amount_reserved ev ->
        let open_cmd =
          Dispatch_open_ticket
            {
              reservation_id = ev.reservation_id;
              correlation_id = ev.correlation_id;
              book_id = payload.book_id;
              symbol = payload.symbol;
              side = payload.side;
              quantity = payload.quantity;
              directive = payload.directive;
            }
        in
        ( Working
            { reservation_id = ev.reservation_id; correlation_id = ev.correlation_id },
          [ open_cmd ] )
    | Awaiting_reservation _, Reservation_rejected ev ->
        (Compensated { reason = "rejected_by_account: " ^ ev.reason }, [])
    (* ---------- Working ---------- *)
    | Working _, Ticket_fill_recorded ev ->
        (* The ticket finished executing: one Commit_fill_command for
           the cumulative executed quantity (at the ticket's VWAP)
           settles the whole reservation. The saga stays Working
           until Account confirms with Reservation_filled. *)
        let cmd =
          Dispatch_commit_fill
            {
              correlation_id = ev.correlation_id;
              reservation_id = ev.reservation_id;
              quantity = ev.fill_quantity;
              price = ev.fill_price;
              fee = ev.fee;
            }
        in
        (s, [ cmd ])
    | Working { reservation_id; _ }, Reservation_filled _ ->
        (* Account confirmed the single commit drew the reservation
           to zero. Terminal — nothing left to release. *)
        (Settled { reservation_id }, [])
    | Working { reservation_id; correlation_id }, Ticket_cancelled ev ->
        let cmd =
          Dispatch_release { correlation_id; reservation_id = ev.reservation_id }
        in
        (Released { reservation_id; reason = "cancelled: " ^ ev.reason }, [ cmd ])
    | Working { reservation_id; correlation_id }, Ticket_failed ev ->
        let cmd =
          Dispatch_release { correlation_id; reservation_id = ev.reservation_id }
        in
        (Released { reservation_id; reason = "failed: " ^ ev.reason }, [ cmd ])
    (* Late / duplicate events for already-terminated states: silently
       absorbed (idempotent fall-through). *)
    | _, _ -> (s, [])

  let is_terminal = function
    | Settled _ | Released _ | Compensated _ -> true
    | Awaiting_reservation _ | Working _ -> false
end

module Engine = Workflow_engine.Make (Definition) (Workflow_engine.In_memory_store)
