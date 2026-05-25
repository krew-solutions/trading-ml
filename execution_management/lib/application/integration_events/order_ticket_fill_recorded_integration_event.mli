(** Integration event: an OrderTicket finished executing and its
    cumulative fill is recorded. Published once, when the ticket is
    fully closed (Ev_ticket_completed), carrying the ticket-level
    totals: cumulative filled quantity, the volume-weighted average
    fill price, and total fees. order_management's saga consumes it
    and dispatches a single [Commit_fill_command] that settles the
    whole reservation at Account — there is no per-leg commit.

    Generated wire shape from
    [shared/contracts/execution_management/integration_events/order_ticket_fill_recorded_integration_event.atd]. *)

include module type of Order_ticket_fill_recorded_integration_event_t

include module type of Order_ticket_fill_recorded_integration_event_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t

val of_domain :
  correlation_id:string ->
  Execution_management.Order_ticket.Events.Ticket_completed.t ->
  t
