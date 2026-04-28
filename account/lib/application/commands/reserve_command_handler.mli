(** Handler for {!Reserve_command.t}. Dispatches outcomes via
    publisher function-types supplied by the composition root —
    success path through [~publish_amount_reserved], invariant
    violation through [~publish_reservation_rejected]. The
    handler does NOT depend on {!Bus.Event_bus}; composition root
    supplies the closures.

    {b Parse failure} (bad symbol, bad side string) raises
    [Invalid_argument]; HTTP is expected to validate up-front, so
    this would only fire on a contract-violating caller. *)

module Amount_reserved =
  Account_integration_events.Amount_reserved_integration_event
module Reservation_rejected =
  Account_integration_events.Reservation_rejected_integration_event

val make :
  portfolio:Account.Portfolio.t ref ->
  next_reservation_id:(unit -> int) ->
  slippage_buffer:float ->
  fee_rate:float ->
  publish_amount_reserved:(Amount_reserved.t -> unit) ->
  publish_reservation_rejected:(Reservation_rejected.t -> unit) ->
  Reserve_command.t ->
  unit
