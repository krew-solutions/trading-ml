(** ACL: translate [Reservation_filled_integration_event] into
    {!Commit_actual_fill_command} and dispatch into PM's workflow.

    The fill IE carries no occurred_at — Account's
    {!Account.Portfolio.Events.Reservation_filled.t} does not record
    one (the commit lands synchronously inside the saga). The ACL
    stamps the inbound moment by reading ambient time from the
    injected [~now] clock; PM uses [occurred_at] only for audit
    ordering, not for any pricing or risk calculation. In live
    deployments [now] wraps wall-clock; in backtest deployments it
    reads a virtual clock advanced from the bar stream. See ADR
    0013.

    The IE carries no [book_id] (Account is currently single-book
    and its aggregate has no [book_id] field). The ACL applies a
    project-wide sentinel ["alpha"], matching the convention used by
    the test harness. Promoting [book_id] into Account's outbound
    shape is tracked as a follow-up. *)

val handle :
  now:(unit -> int64) ->
  dispatch_commit_actual_fill:
    (Portfolio_management_commands.Commit_actual_fill_command.t -> unit) ->
  Reservation_filled_integration_event.t ->
  unit
