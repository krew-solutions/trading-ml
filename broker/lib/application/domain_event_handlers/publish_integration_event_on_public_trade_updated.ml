module Trade_printed = Broker_integration_events.Trade_printed_integration_event

let handle
    ~(publish_trade_printed : Trade_printed.t -> unit)
    (ev : Broker_domain.Remote_broker.Events.Remote_public_trade_updated.t) : unit =
  publish_trade_printed (Trade_printed.of_domain ev)
