module Amount_reserved = Account_integration_events.Amount_reserved_integration_event
module Reservation_released =
  Account_integration_events.Reservation_released_integration_event
module Reservation_rejected =
  Account_integration_events.Reservation_rejected_integration_event
module Order_accepted = Broker_integration_events.Order_accepted_integration_event
module Order_rejected = Broker_integration_events.Order_rejected_integration_event
module Order_unreachable = Broker_integration_events.Order_unreachable_integration_event

let envelope kind payload : Yojson.Safe.t =
  `Assoc [ ("kind", `String kind); ("payload", payload) ]

module Make (Bus : Bus.Event_bus.S) = struct
  let attach
      (registry : Stream.t)
      ~(events_amount_reserved : Amount_reserved.t Bus.t)
      ~(events_reservation_released : Reservation_released.t Bus.t)
      ~(events_reservation_rejected : Reservation_rejected.t Bus.t)
      ~(events_order_accepted : Order_accepted.t Bus.t)
      ~(events_order_rejected : Order_rejected.t Bus.t)
      ~(events_order_unreachable : Order_unreachable.t Bus.t) : unit =
    let publish kind to_yojson ev =
      Stream.publish_order registry (envelope kind (to_yojson ev))
    in
    let _ : Bus.subscription =
      Bus.subscribe events_amount_reserved
        (publish "amount_reserved" Amount_reserved.yojson_of_t)
    in
    let _ : Bus.subscription =
      Bus.subscribe events_reservation_released
        (publish "reservation_released" Reservation_released.yojson_of_t)
    in
    let _ : Bus.subscription =
      Bus.subscribe events_reservation_rejected
        (publish "reservation_rejected" Reservation_rejected.yojson_of_t)
    in
    let _ : Bus.subscription =
      Bus.subscribe events_order_accepted
        (publish "order_accepted" Order_accepted.yojson_of_t)
    in
    let _ : Bus.subscription =
      Bus.subscribe events_order_rejected
        (publish "order_rejected" Order_rejected.yojson_of_t)
    in
    let _ : Bus.subscription =
      Bus.subscribe events_order_unreachable
        (publish "order_unreachable" Order_unreachable.yojson_of_t)
    in
    ()
end
