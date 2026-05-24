module Order_filled = Broker_integration_events.Order_filled_integration_event

let handle
    ~(publish_order_filled : Order_filled.t -> unit)
    ~(origin_correlation_id : placement_id:int -> string option)
    (ev : Broker_domain.Remote_broker.Events.Order_filled.t) : unit =
  match origin_correlation_id ~placement_id:ev.placement_id with
  | None ->
      Log.warn "[broker] fill for placement_id=%d has no Submit correlation_id — skipping"
        ev.placement_id
  | Some correlation_id ->
      publish_order_filled (Order_filled.of_domain ~correlation_id ev)
