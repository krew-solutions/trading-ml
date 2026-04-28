module Reservation_released =
  Account_integration_events.Reservation_released_integration_event

let to_integration_event (ev : Account.Portfolio.Events.Reservation_released.t) :
    Reservation_released.t =
  {
    reservation_id = ev.reservation_id;
    side = Core.Side.to_string ev.side;
    instrument = Queries.Instrument_view_model.of_domain ev.instrument;
  }

let handle
    ~(publish_reservation_released : Reservation_released.t -> unit)
    (ev : Account.Portfolio.Events.Reservation_released.t) : unit =
  publish_reservation_released (to_integration_event ev)
