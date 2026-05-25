module Trade_executed = Broker_integration_events.Trade_executed_integration_event

let handle
    ~(publish_trade_executed : Trade_executed.t -> unit)
    ~(origin_correlation_id : placement_id:int -> string option)
    (ev : Broker_domain.Remote_broker.Events.Trade_executed.t) : unit =
  match origin_correlation_id ~placement_id:ev.placement_id with
  | None ->
      Log.warn
        "[broker] trade for placement_id=%d has no Submit correlation_id — skipping"
        ev.placement_id
  | Some correlation_id ->
      publish_trade_executed (Trade_executed.of_domain ~correlation_id ev)
