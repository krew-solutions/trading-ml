module Bar_updated = Broker_integration_events.Bar_updated_integration_event

let handle
    ~(publish_bar_updated : Bar_updated.t -> unit)
    (ev : Broker_domain.Remote_broker.Events.Remote_bar_updated.t) : unit =
  publish_bar_updated (Bar_updated.of_domain ev)
