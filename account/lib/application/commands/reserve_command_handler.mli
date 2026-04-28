(** Handler for {!Reserve_command.t}. Fire-and-forget per the
    async {!Bus.Command_bus} contract — outcomes flow exclusively
    through the per-event {!Bus.Event_bus.t} fan-out:

    - {!Account.Portfolio.try_reserve} returns [Ok] → mutate
      [~portfolio] ref, publish {!Amount_reserved.t}.
    - Returns [Error Insufficient_cash | Insufficient_qty] →
      publish {!Reservation_rejected.t}, portfolio ref unchanged.

    {b Parse failure} (bad symbol, bad side string) raises
    [Invalid_argument]; HTTP is expected to validate up-front, so
    this would only fire on a contract-violating caller. *)

module Amount_reserved = Account_integration_events.Amount_reserved_integration_event
module Reservation_rejected = Account_integration_events.Reservation_rejected_integration_event

val make :
  portfolio:Account.Portfolio.t ref ->
  next_reservation_id:(unit -> int) ->
  slippage_buffer:float ->
  fee_rate:float ->
  events_amount_reserved:Amount_reserved.t Bus.Event_bus.t ->
  events_reservation_rejected:Reservation_rejected.t Bus.Event_bus.t ->
  Reserve_command.t ->
  unit
