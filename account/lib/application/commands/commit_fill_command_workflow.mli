(** Workflow for {!Commit_fill_command.t}: parse → commit fill on
    the aggregate → publish exactly one outbound integration event,
    selected by the aggregate's outcome:

    - [Drawn_down] → [Reservation_drawn_down] IE (partial draw,
      reservation stays in the ledger).
    - [Fully_committed] → [Reservation_filled] IE (terminal draw,
      reservation removed).

    Both carry the atomic post-image of cash and position so
    consumers cannot observe a state that violates
    [equity = cash + Σ qty × mark].

    A reservation-not-found error is dropped silently — the
    contract is idempotent compensation, mirroring how the
    {!Release_command_workflow} handles the same situation. A
    duplicated or late fill against a reservation that was
    already released emits no IE and returns [`Ok ()]. An
    overfill is propagated to the caller (today the factory logs
    and drops; future reconcile work may surface it).

    See ADR 0028 for the progressive-drawdown contract. *)

module Reservation_drawn_down :
    module type of Account_integration_events.Reservation_drawn_down_integration_event

module Reservation_filled :
    module type of Account_integration_events.Reservation_filled_integration_event

val execute :
  portfolio:Account.Portfolio.t ref ->
  publish_reservation_drawn_down:(Reservation_drawn_down.t -> unit) ->
  publish_reservation_filled:(Reservation_filled.t -> unit) ->
  Commit_fill_command.t ->
  (unit, Commit_fill_command_handler.handle_error) Rop.t
