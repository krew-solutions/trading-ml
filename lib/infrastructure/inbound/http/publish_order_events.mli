(** SSE projector: per-event-type bus callbacks that forward each
    event to the [order] SSE channel of [registry] as a discriminated
    envelope:

    {[ { "kind": <variant>, "payload": <event-dto-yojson> } ]}

    Bus-agnostic. Each [handle_*] function is registered as the
    callback for the matching consumer at the composition root. *)

module Amount_reserved = Account_integration_events.Amount_reserved_integration_event
module Reservation_released =
  Account_integration_events.Reservation_released_integration_event
module Reservation_rejected =
  Account_integration_events.Reservation_rejected_integration_event
module Order_accepted = Broker_integration_events.Order_accepted_integration_event
module Order_rejected = Broker_integration_events.Order_rejected_integration_event
module Order_unreachable = Broker_integration_events.Order_unreachable_integration_event

val handle_amount_reserved : registry:Stream.t -> Amount_reserved.t -> unit
val handle_reservation_released : registry:Stream.t -> Reservation_released.t -> unit
val handle_reservation_rejected : registry:Stream.t -> Reservation_rejected.t -> unit
val handle_order_accepted : registry:Stream.t -> Order_accepted.t -> unit
val handle_order_rejected : registry:Stream.t -> Order_rejected.t -> unit
val handle_order_unreachable : registry:Stream.t -> Order_unreachable.t -> unit
