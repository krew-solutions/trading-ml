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

let publish ~registry kind to_yojson ev =
  Stream.publish_order registry (envelope kind (to_yojson ev))

let handle_amount_reserved ~registry (ev : Amount_reserved.t) : unit =
  publish ~registry "amount_reserved" Amount_reserved.yojson_of_t ev

let handle_reservation_released ~registry (ev : Reservation_released.t) : unit =
  publish ~registry "reservation_released" Reservation_released.yojson_of_t ev

let handle_reservation_rejected ~registry (ev : Reservation_rejected.t) : unit =
  publish ~registry "reservation_rejected" Reservation_rejected.yojson_of_t ev

let handle_order_accepted ~registry (ev : Order_accepted.t) : unit =
  publish ~registry "order_accepted" Order_accepted.yojson_of_t ev

let handle_order_rejected ~registry (ev : Order_rejected.t) : unit =
  publish ~registry "order_rejected" Order_rejected.yojson_of_t ev

let handle_order_unreachable ~registry (ev : Order_unreachable.t) : unit =
  publish ~registry "order_unreachable" Order_unreachable.yojson_of_t ev
