(** ROP pipeline for processing {!Reserve_command.t}.

    Composes parsing, command handler and domain-event handler:
    {ol
    {- Parse the wire-shaped {!Reserve_command.t} into domain
       values (side, instrument, quantity, price). Parse failure
       (bad symbol, bad side string) raises [Invalid_argument];
       HTTP is expected to validate up-front, so this would only
       fire on a contract-violating caller.}
    {- {!Reserve_command_handler.handle} — runs the command,
       yields an {!Account.Portfolio.Events.Amount_reserved.t}
       domain event on success or a
       {!Account.Portfolio.reservation_error} on invariant
       violation (insufficient cash for a buy, insufficient
       quantity for a sell).}
    {- {!Account_domain_event_handlers.Publish_integration_event_on_amount_reserved.handle}
       — projects the domain event into the outbound
       integration-event DTO and calls [~publish_amount_reserved].}
    }

    On the failure track, projects the [reservation_error] into a
    {!Reservation_rejected_integration_event.t} and calls
    [~publish_reservation_rejected]; the same error list is also
    propagated through the [Rop.t] return so the caller (command
    bus, tests) can branch. Symmetric with
    {!Release_command_workflow.execute}. *)

module Amount_reserved = Account_integration_events.Amount_reserved_integration_event
module Reservation_rejected =
  Account_integration_events.Reservation_rejected_integration_event

val execute :
  portfolio:Account.Portfolio.t ref ->
  next_reservation_id:(unit -> int) ->
  slippage_buffer:Decimal.t ->
  fee_rate:Decimal.t ->
  publish_amount_reserved:(Amount_reserved.t -> unit) ->
  publish_reservation_rejected:(Reservation_rejected.t -> unit) ->
  Reserve_command.t ->
  (unit, Account.Portfolio.reservation_error) Rop.t
