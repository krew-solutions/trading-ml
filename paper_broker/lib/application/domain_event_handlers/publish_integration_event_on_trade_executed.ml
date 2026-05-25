module Trade_executed = Paper_broker_integration_events.Trade_executed_integration_event

let handle
    ~(publish_trade_executed : Trade_executed.t -> unit)
    ~(correlation_id : string)
    (ev : Paper_broker.Order.Events.Trade_executed.t) : unit =
  publish_trade_executed (Trade_executed.of_domain ~correlation_id ev)
