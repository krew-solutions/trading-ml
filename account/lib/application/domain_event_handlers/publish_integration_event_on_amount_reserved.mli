(** Domain-event handler for {!Account.Portfolio.Events.Amount_reserved}.

    Per CLAUDE.md: "Отправка Domain Event за пределы Bounded
    Context осуществляется обработчиком доменного события, который
    конвертирует Domain Event в Integration Event и передает его в
    реализацию Hexagonal Port." Symmetric counterpart of
    {!Publish_integration_event_on_reservation_released} on the
    successful-reservation path. *)

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
