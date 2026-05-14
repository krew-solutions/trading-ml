module Order_cancelled = Paper_broker_integration_events.Order_cancelled_integration_event

let handle
    ~(publish_order_cancelled : Order_cancelled.t -> unit)
    ~(correlation_id : string)
    ~(reservation_id : int)
    (ev : Paper_broker.Order.Events.Order_cancelled.t) : unit =
  publish_order_cancelled (Order_cancelled.of_domain ~correlation_id ~reservation_id ev)
