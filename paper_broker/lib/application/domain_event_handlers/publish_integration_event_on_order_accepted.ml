module Order_accepted = Paper_broker_integration_events.Order_accepted_integration_event

let handle
    ~(publish_order_accepted : Order_accepted.t -> unit)
    ~(correlation_id : string)
    ~(reservation_id : int)
    (ev : Paper_broker.Order.Events.Order_accepted.t) : unit =
  publish_order_accepted (Order_accepted.of_domain ~correlation_id ~reservation_id ev)
