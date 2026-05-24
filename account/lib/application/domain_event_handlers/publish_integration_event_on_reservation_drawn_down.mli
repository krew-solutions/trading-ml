(** Domain Event handler: translates
    {!Account.Portfolio.Events.Reservation_drawn_down.t} into
    {!Account_integration_events.Reservation_drawn_down_integration_event.t}
    and publishes it through the supplied port closure.

    Naming follows the project convention
    [publish_integration_event_on_<event>]. *)

module Reservation_drawn_down :
    module type of Account_integration_events.Reservation_drawn_down_integration_event

val handle :
  publish_reservation_drawn_down:(Reservation_drawn_down.t -> unit) ->
  correlation_id:string ->
  Account.Portfolio.Events.Reservation_drawn_down.t ->
  unit
