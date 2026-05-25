(** Order_process_manager — the cross-BC saga that owns the
    full reservation-cycle lifecycle of an approved trader intent.

    Inbound events the saga reacts to:

    - PTR: [Trade_intent_approved]                 (saga start)
    - Account: [Amount_reserved]                   (Working entry)
    - Account: [Reservation_rejected]              (compensation)
    - EM: [Order_ticket_fill_recorded]             (ticket closed: commit)
    - Account: [Reservation_filled]                (terminal: settled)
    - EM: [Order_ticket_cancelled]                 (terminal: release)
    - EM: [Order_ticket_failed]                    (terminal: release)

    Outbound commands the saga dispatches:

    - Account: [Reserve_command]                   (at start)
    - EM: [Open_order_ticket_command]              (cross-BC wire)
    - Account: [Commit_fill_command]               (once, at ticket close)
    - Account: [Release_command]                   (at cancel / fail)

    A ticket reserves once and commits once: [Order_ticket_fill_recorded]
    fires a single time when the ticket is fully filled, carrying the
    cumulative executed quantity at the ticket's VWAP, and the saga
    turns it into one [Commit_fill_command]. Account confirms with
    [Reservation_filled], which settles the saga. (Progressive
    per-fill drawdown — ADR 0028 — is not exercised by this flow;
    the single commit draws the reservation to zero in one shot.)

    {b Known gap.} A ticket cancelled or failed after a partial fill
    emits no [Order_ticket_fill_recorded] (it fires only at full
    fill), so the executed portion is not committed and the whole
    reservation is released. Settling a partial-then-cancelled ticket
    is deferred to a reconcile path / future step.

    State machine:

    {v
      Awaiting_reservation
        ├─ Amount_reserved          → Working           (+ Dispatch_open_ticket)
        └─ Reservation_rejected     → Compensated      (terminal)

      Working
        ├─ Ticket_fill_recorded     → Working          (+ Dispatch_commit_fill)
        ├─ Reservation_filled       → Settled          (terminal, no command)
        ├─ Ticket_cancelled         → Released         (+ Dispatch_release)
        └─ Ticket_failed            → Released         (+ Dispatch_release)
    v}

    State keyed by the saga-instance [correlation_id], minted by
    the saga initiator (today PM's reconciler in
    {!Trade_intents_planned_integration_event.leg.correlation_id})
    and echoed verbatim by every downstream BC. *)

type directive_payload = { directive_kind : string; directive_params : string option }
(** Wire-shape execution directive carried alongside the saga
    payload (kind tag + optional per-strategy JSON params blob). *)

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
  | Settled of { reservation_id : int }
  | Released of { reservation_id : int; reason : string }
  | Compensated of { reason : string }

type event =
  | Amount_reserved of
      Order_management_external_integration_events.Amount_reserved_integration_event.t
  | Reservation_rejected of
      Order_management_external_integration_events.Reservation_rejected_integration_event
      .t
  | Ticket_fill_recorded of
      Order_management_external_integration_events
      .Order_ticket_fill_recorded_integration_event
      .t
  | Reservation_filled of
      Order_management_external_integration_events.Reservation_filled_integration_event.t
  | Ticket_cancelled of
      Order_management_external_integration_events
      .Order_ticket_cancelled_integration_event
      .t
  | Ticket_failed of
      Order_management_external_integration_events.Order_ticket_failed_integration_event.t

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

module Definition :
  Workflow_engine.WORKFLOW
    with type state = state
     and type event = event
     and type command = command

module Engine :
    module type of Workflow_engine.Make (Definition) (Workflow_engine.In_memory_store)

val initial_payload :
  ?directive:directive_payload ->
  book_id:string ->
  symbol:string ->
  side:string ->
  quantity:string ->
  unit ->
  payload

val reserve_for_start :
  correlation_id:string -> payload:payload -> price:string -> command
