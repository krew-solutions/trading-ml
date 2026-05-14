(** Workflow for {!Commit_fill_command.t}: parse → commit fill on
    the aggregate → publish a single atomic [Reservation_filled]
    integration event carrying both the new position snapshot and
    the new cash balance.

    A reservation-not-found error is dropped silently — the
    contract is idempotent compensation, mirroring how the
    {!Release_command_workflow} handles the same situation. A
    duplicated or late fill against a reservation that was
    already released emits no IE and returns [`Ok ()]. *)

module Reservation_filled :
    module type of Account_integration_events.Reservation_filled_integration_event

val execute :
  portfolio:Account.Portfolio.t ref ->
  publish_reservation_filled:(Reservation_filled.t -> unit) ->
  Commit_fill_command.t ->
  (unit, Commit_fill_command_handler.handle_error) Rop.t
