(** Domain-event handler for {!Account.Portfolio.Events.Reservation_released}.

    Bounded-context boundary discipline: a Domain Event leaves the
    BC only via a domain-event handler that translates it into an
    Integration Event DTO and hands the DTO to a Hexagonal Port. No
    direct publishing of domain values across the boundary. This
    module projects the release-path domain event into the outbound
    integration-event DTO and hands it to the supplied publisher
    port. *)

module Reservation_released =
  Account_integration_events.Reservation_released_integration_event

val handle :
  publish_reservation_released:(Reservation_released.t -> unit) ->
  Account.Portfolio.Events.Reservation_released.t ->
  unit
(** Convert a domain event into an integration-event DTO via
    {!Reservation_released.of_domain} and call
    [~publish_reservation_released] with it. The composition root
    wires that port to {!Bus.Event_bus.publish} on the outbound
    Reservation_released event bus. *)
