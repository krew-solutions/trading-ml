(** Integration event: the OrderTicket aggregate observed a
    fill from one of its placements. Published once per
    Ev_placement_filled. order_management's saga consumes it
    and dispatches [Commit_fill_command] to Account.

    Generated wire shape from
    [shared/contracts/execution_management/integration_events/order_ticket_fill_recorded_integration_event.atd]. *)

include module type of Order_ticket_fill_recorded_integration_event_t

include module type of Order_ticket_fill_recorded_integration_event_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t

val of_domain :
  correlation_id:string ->
  reservation_id:Execution_management.Order_ticket.Values.Reservation_id.t ->
  Execution_management.Order_ticket.Events.Placement_filled.t ->
  t
