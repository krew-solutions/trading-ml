(** Handler for {!Submit_order_command.t}. Fire-and-forget — outcomes
    flow exclusively through the three port callbacks:

    - {!Broker.place_order} returns an order with [status = Rejected]
      → [publish_rejected].
    - {!Broker.place_order} returns any other status → [publish_accepted].
    - {!Broker.place_order} raises (transport error, parse failure
      of the wire DTO) → [publish_unreachable].

    {b Invariant.} Exactly one of the three ports fires per call.
    Account's compensation handler on {!Order_rejected} /
    {!Order_unreachable} relies on this for correct rollback.

    The handler is bus-agnostic: it depends on plain [_ -> unit]
    ports, not on any specific transport. The composition root binds
    these ports to whichever bus implementation is in use. *)

module Order_accepted = Broker_integration_events.Order_accepted_integration_event
module Order_rejected = Broker_integration_events.Order_rejected_integration_event
module Order_unreachable = Broker_integration_events.Order_unreachable_integration_event

val make :
  broker:Broker.client ->
  publish_accepted:(Order_accepted.t -> unit) ->
  publish_rejected:(Order_rejected.t -> unit) ->
  publish_unreachable:(Order_unreachable.t -> unit) ->
  Submit_order_command.t ->
  unit
