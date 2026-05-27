(** Domain Event handler: projects
    {!Broker_domain.Remote_broker.Events.Remote_public_trade_updated.t}
    into {!Broker_integration_events.Trade_printed_integration_event.t}
    via [of_domain] and publishes it through the supplied port closure. *)

module Trade_printed :
    module type of Broker_integration_events.Trade_printed_integration_event

val handle :
  publish_trade_printed:(Trade_printed.t -> unit) ->
  Broker_domain.Remote_broker.Events.Remote_public_trade_updated.t ->
  unit
