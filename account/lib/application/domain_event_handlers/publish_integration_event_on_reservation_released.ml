module Reservation_released =
  Account_integration_events.Reservation_released_integration_event

let handle
    ~(publish_reservation_released : Reservation_released.t -> unit)
    (ev : Account.Portfolio.Events.Reservation_released.t) : unit =
  publish_reservation_released (Reservation_released.of_domain ev)
