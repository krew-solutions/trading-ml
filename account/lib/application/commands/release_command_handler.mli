(** Handler for {!Release_command.t}. Fire-and-forget per the
    async {!Bus.Command_bus} contract.

    - {!Account.Portfolio.try_release} returns [Ok] → mutate
      [~portfolio] ref, publish {!Reservation_released.t}.
    - Returns [Error (Reservation_not_found _)] → silent no-op
      (idempotent compensation: a duplicated or late
      {!Order_rejected.t} for a reservation that's already been
      released doesn't crash the system). *)

module Reservation_released = Account_integration_events.Reservation_released_integration_event

val make :
  portfolio:Account.Portfolio.t ref ->
  events_reservation_released:Reservation_released.t Bus.Event_bus.t ->
  Release_command.t ->
  unit
