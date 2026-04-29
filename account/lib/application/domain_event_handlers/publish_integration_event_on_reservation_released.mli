(** Domain-event handler for {!Account.Portfolio.Events.Reservation_released}.

    Per CLAUDE.md: "Отправка Domain Event за пределы Bounded
    Context осуществляется обработчиком доменного события, который
    конвертирует Domain Event в Integration Event и передает его в
    реализацию Hexagonal Port." This module is exactly that: it
    projects the domain event into the outbound integration-event
    DTO and hands the DTO to the supplied publisher port. *)

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
