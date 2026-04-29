(** SSE projector: subscribes to every Account / Broker
    integration-event bus and forwards each event to the [order]
    SSE channel of [registry] as a discriminated envelope:

    {[ { "kind": <variant>, "payload": <event-dto-yojson> } ]}

    Functor over {!Bus.Event_bus.S} — composition root applies it
    with whichever concrete bus implementation is in use
    (in-memory today, Kafka tomorrow). *)

module Amount_reserved = Account_integration_events.Amount_reserved_integration_event
module Reservation_released =
  Account_integration_events.Reservation_released_integration_event
module Reservation_rejected =
  Account_integration_events.Reservation_rejected_integration_event
module Order_accepted = Broker_integration_events.Order_accepted_integration_event
module Order_rejected = Broker_integration_events.Order_rejected_integration_event
module Order_unreachable = Broker_integration_events.Order_unreachable_integration_event

module Make (Bus : Bus.Event_bus.S) : sig
  val attach :
    Stream.t ->
    events_amount_reserved:Amount_reserved.t Bus.t ->
    events_reservation_released:Reservation_released.t Bus.t ->
    events_reservation_rejected:Reservation_rejected.t Bus.t ->
    events_order_accepted:Order_accepted.t Bus.t ->
    events_order_rejected:Order_rejected.t Bus.t ->
    events_order_unreachable:Order_unreachable.t Bus.t ->
    unit
end
