module Trade_intents_planned =
  Portfolio_management_integration_events.Trade_intents_planned_integration_event

let handle
    ~(publish_trade_intents_planned : Trade_intents_planned.t -> unit)
    (ev : Portfolio_management.Reconciliation.Events.Trades_planned.t) : unit =
  publish_trade_intents_planned (Trade_intents_planned.of_domain ev)
