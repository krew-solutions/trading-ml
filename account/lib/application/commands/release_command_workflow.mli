(** ROP pipeline for {!Release_command.t}.

    Composes {!Release_command_handler.handle} with the
    success-path {!Reservation_released} projection. There is
    no public failure-path integration event today: a duplicated
    or late release for an unknown reservation surfaces only via
    the [Rop.t] tail, which the bus dispatcher discards
    idempotently. *)

module Reservation_released =
  Account_integration_events.Reservation_released_integration_event

val execute :
  portfolio:Account.Portfolio.t ref ->
  publish_reservation_released:(Reservation_released.t -> unit) ->
  Release_command.t ->
  (unit, Release_command_handler.handle_error) Rop.t
