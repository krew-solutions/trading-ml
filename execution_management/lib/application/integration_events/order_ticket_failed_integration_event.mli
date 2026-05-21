(** Integration event: an OrderTicket reached terminal Failed —
    the strategy gave up. *)

include module type of Order_ticket_failed_integration_event_t

include module type of Order_ticket_failed_integration_event_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t

val of_domain :
  correlation_id:string -> Execution_management.Order_ticket.Events.Ticket_failed.t -> t
