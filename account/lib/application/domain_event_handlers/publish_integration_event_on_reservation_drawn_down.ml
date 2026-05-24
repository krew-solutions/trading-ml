module Reservation_drawn_down =
  Account_integration_events.Reservation_drawn_down_integration_event

let handle
    ~(publish_reservation_drawn_down : Reservation_drawn_down.t -> unit)
    ~(correlation_id : string)
    (ev : Account.Portfolio.Events.Reservation_drawn_down.t) : unit =
  publish_reservation_drawn_down (Reservation_drawn_down.of_domain ~correlation_id ev)
