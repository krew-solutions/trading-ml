(** Domain Event handler: projects
    {!Broker_domain.Remote_broker.Events.Trade_executed.t} into
    {!Broker_integration_events.Trade_executed_integration_event.t}
    via [of_domain] and publishes it through the supplied port
    closure.

    [origin_correlation_id] is an injected lookup the handler
    uses to resolve the saga-instance id from the broker's
    command log, keyed on the event's [placement_id]. The
    lookup is a port (function type) so the handler is
    independent of how the log is implemented. A miss
    ([None]) is logged at warn and the event is dropped — a
    trade arrived for a placement this broker never recorded a
    Submit for (rotated cache, replay before catch-up, or an
    order placed out-of-band). *)

module Trade_executed :
    module type of Broker_integration_events.Trade_executed_integration_event

val handle :
  publish_trade_executed:(Trade_executed.t -> unit) ->
  origin_correlation_id:(placement_id:int -> string option) ->
  Broker_domain.Remote_broker.Events.Trade_executed.t ->
  unit
