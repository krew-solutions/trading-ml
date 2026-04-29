(** ROP pipeline for processing {!Release_command.t}.

    Composes two handlers, command handler first:
    {ol
    {- {!Release_command_handler.handle} — runs the command,
       yields an {!Account.Portfolio.Events.Reservation_released.t}
       domain event on success.}
    {- {!Account_domain_event_handlers.Publish_integration_event_on_reservation_released.handle}
       — projects the domain event into the outbound
       integration-event DTO and calls the supplied publisher
       function.}} *)

module Reservation_released =
  Account_integration_events.Reservation_released_integration_event

val execute :
  portfolio:Account.Portfolio.t ref ->
  publish_reservation_released:(Reservation_released.t -> unit) ->
  Release_command.t ->
  (unit, Account.Portfolio.release_error) Rop.t
