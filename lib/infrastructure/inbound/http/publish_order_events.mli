(** SSE projector: subscribes to every Account / Broker
    integration-event bus and forwards each event to the [order]
    SSE channel of [registry] as a discriminated envelope:

    {[ { "kind": <variant>, "payload": <event-dto-yojson> } ]}

    The browser-side [addEventListener("order", ...)] handler
    branches on [kind]; payload shape is the per-event DTO,
    [@@deriving yojson] auto-generated. Filtering by
    [reservation_id] (or any other field) is the browser's
    concern — this projector publishes everything. *)

module Amount_reserved = Account_integration_events.Amount_reserved_integration_event
module Reservation_released = Account_integration_events.Reservation_released_integration_event
module Reservation_rejected = Account_integration_events.Reservation_rejected_integration_event
module Order_accepted = Broker_integration_events.Order_accepted_integration_event
module Order_rejected = Broker_integration_events.Order_rejected_integration_event
module Order_unreachable = Broker_integration_events.Order_unreachable_integration_event

val attach :
  Stream.t ->
  events_amount_reserved:Amount_reserved.t Bus.Event_bus.t ->
  events_reservation_released:Reservation_released.t Bus.Event_bus.t ->
  events_reservation_rejected:Reservation_rejected.t Bus.Event_bus.t ->
  events_order_accepted:Order_accepted.t Bus.Event_bus.t ->
  events_order_rejected:Order_rejected.t Bus.Event_bus.t ->
  events_order_unreachable:Order_unreachable.t Bus.Event_bus.t ->
  unit
(** Wire all six subscriptions. Subscriptions are anonymous —
    they live for the lifetime of the process; for an MVP that
    matches reality (server runs continuously, registry lives as
    long as the server). *)
