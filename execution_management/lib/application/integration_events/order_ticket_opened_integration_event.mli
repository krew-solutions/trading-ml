(** Integration event: an OrderTicket was opened. Generated wire
    shape from
    [shared/contracts/execution_management/integration_events/order_ticket_opened_integration_event.atd].

    The [correlation_id] is the saga-instance key (echoed verbatim
    from [Trade_intent_approved]) and is not on the domain event;
    the application layer threads it in via [of_domain]. *)

include module type of Order_ticket_opened_integration_event_t

include module type of Order_ticket_opened_integration_event_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t

val of_domain :
  correlation_id:string -> Execution_management.Order_ticket.Events.Ticket_opened.t -> t
