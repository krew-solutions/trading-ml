(** ROP pipeline for processing {!Release_command.t}.

    Steps in order:
    {ol
    {- Invoke {!Account.Portfolio.try_release} on the shared
       portfolio ref. On success this mutates the ref and yields
       a domain event {!Account.Portfolio.reservation_released};
       on [Reservation_not_found] the workflow silently no-ops
       (idempotent compensation — duplicated or late rejection
       events for an already-released reservation must not crash).}
    {- Hand the domain event to
       {!Account_domain_event_handlers.Publish_integration_event_on_reservation_released.handle}
       which projects it into the outbound integration-event DTO and
       calls the supplied publisher port.}}

    The workflow itself does not depend on {!Bus} — only on the
    publisher port supplied by the command handler at the bus
    boundary. *)

module Reservation_released =
  Account_integration_events.Reservation_released_integration_event

val execute :
  portfolio:Account.Portfolio.t ref ->
  publish_reservation_released:(Reservation_released.t -> unit) ->
  Release_command.t ->
  unit
