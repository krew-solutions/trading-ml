(** Domain-event handler for {!Account.Portfolio.Events.Amount_reserved}.

    Bounded-context boundary discipline: a Domain Event leaves the
    BC only via a domain-event handler that translates it into an
    Integration Event DTO and hands the DTO to a Hexagonal Port. No
    direct publishing of domain values across the boundary. This
    handler is the successful-reservation half of that mechanism;
    {!Publish_integration_event_on_reservation_released} is its
    symmetric counterpart on the release path. *)

module Amount_reserved = Account_integration_events.Amount_reserved_integration_event

val handle :
  publish_amount_reserved:(Amount_reserved.t -> unit) ->
  Account.Portfolio.Events.Amount_reserved.t ->
  unit
(** Convert a domain event into an integration-event DTO via
    {!Amount_reserved.of_domain} and call [~publish_amount_reserved]
    with it. The composition root wires that port to
    {!Bus.Event_bus.publish} on the outbound Amount_reserved event
    bus. *)
