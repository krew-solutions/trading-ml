module Reservation_filled =
  Account_integration_events.Reservation_filled_integration_event

let handle
    ~(publish_reservation_filled : Reservation_filled.t -> unit)
    ~(correlation_id : string)
    (ev : Account.Portfolio.Events.Reservation_filled.t) : unit =
  publish_reservation_filled (Reservation_filled.of_domain ~correlation_id ev)
