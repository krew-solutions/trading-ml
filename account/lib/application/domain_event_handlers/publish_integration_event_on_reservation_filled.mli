(** Domain Event handler: translates
    {!Account.Portfolio.Events.Reservation_filled.t} into
    {!Account_integration_events.Reservation_filled_integration_event.t}
    and publishes it through the supplied port closure.

    Naming follows the project convention
    [publish_integration_event_on_<event>]. *)

module Reservation_filled :
    module type of Account_integration_events.Reservation_filled_integration_event

val handle :
  publish_reservation_filled:(Reservation_filled.t -> unit) ->
  correlation_id:string ->
  Account.Portfolio.Events.Reservation_filled.t ->
  unit
