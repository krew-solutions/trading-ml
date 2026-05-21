(** Domain Event handler: projects
    {!Broker_domain.Remote_broker.Events.Remote_bar_updated.t} into
    {!Broker_integration_events.Bar_updated_integration_event.t}
    via [of_domain] and publishes it through the supplied port
    closure. *)

module Bar_updated :
    module type of Broker_integration_events.Bar_updated_integration_event

val handle :
  publish_bar_updated:(Bar_updated.t -> unit) ->
  Broker_domain.Remote_broker.Events.Remote_bar_updated.t ->
  unit
