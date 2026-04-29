(** Handler for {!Submit_order_command.t}. Fire-and-forget per the
    async {!Bus.Command_bus} contract — outcomes flow exclusively
    through the per-event {!Bus.Event_bus.t} fan-out:

    - {!Broker.place_order} returns an order with [status = Rejected]
      → publish {!Order_rejected.t}.
    - {!Broker.place_order} returns any other status → publish
      {!Order_accepted.t}.
    - {!Broker.place_order} raises (transport error, parse failure
      of the wire DTO) → publish {!Order_unreachable.t}.

    {b Invariant.} Exactly one event published per call. Account's
    compensation subscriber on {!Order_rejected} / {!Order_unreachable}
    relies on this for correct rollback. *)

module Order_accepted = Broker_integration_events.Order_accepted_integration_event
module Order_rejected = Broker_integration_events.Order_rejected_integration_event
module Order_unreachable = Broker_integration_events.Order_unreachable_integration_event

val make :
  broker:Broker.client ->
  events_accepted:Order_accepted.t Bus.Event_bus.t ->
  events_rejected:Order_rejected.t Bus.Event_bus.t ->
  events_unreachable:Order_unreachable.t Bus.Event_bus.t ->
  Submit_order_command.t ->
  unit
