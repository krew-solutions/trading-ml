module Order_filled = Paper_broker_integration_events.Order_filled_integration_event

let handle
    ~(publish_order_filled : Order_filled.t -> unit)
    ~(correlation_id : string)
    ~(reservation_id : int)
    (ev : Paper_broker.Order.Events.Fill_observed.t) : unit =
  publish_order_filled (Order_filled.of_domain ~correlation_id ~reservation_id ev)
