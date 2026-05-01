(** ROP pipeline for {!Reserve_command.t}.

    Composes {!Reserve_command_handler.handle} with the
    success-path {!Amount_reserved} projection and the
    failure-path {!Reservation_rejected} projection.

    The handler does the entire reservation step internally
    (parse, invariant check, mutate, yield event); the workflow
    only routes the outcome to the correct integration-event
    publisher.

    {1 Failure-track behaviour}

    - {!Reserve_command_handler.Reservation} — a well-formed
      attempt rejected by the aggregate invariant: project to
      {!Reservation_rejected.t} and call
      [~publish_reservation_rejected].
    - {!Reserve_command_handler.Validation} — a malformed wire
      payload that never reached the aggregate: nothing is
      published (semantically there is no "rejection" — this is
      a contract violation by the caller and only surfaces via
      the [Rop.t] tail).

    Symmetric with {!Release_command_workflow.execute}. *)

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
  (unit, Reserve_command_handler.handle_error) Rop.t
