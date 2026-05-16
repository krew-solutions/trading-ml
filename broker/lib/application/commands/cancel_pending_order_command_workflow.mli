(** Command pipeline for {!Cancel_pending_order_command.t}.

    Composes {!Cancel_pending_order_command_handler.handle} with
    two side effects:

    - On [Cancel_confirmed] / [Cancel_pending]: records the
      cancel command's [correlation_id] in the injected
      {!Order_command_log.S} (keyed by [placement_id], audit /
      future compensation), and publishes
      {!Order_cancelled_integration_event} carrying that same
      [correlation_id], the saga's [placement_id], and the
      [cancelled_ts] from broker's injected clock.
    - On [Cancel_refused] / [Unreachable]: no IE is emitted
      today. Terminal-on-venue placements drive the saga via
      their own Order_filled / Order_rejected events; the
      unreachable path is a follow-up once Account grows
      compensation semantics for stuck cancels.
    - On {!Placement_not_found}: surfaced through the [Rop.t]
      error tail; no IE, no log entry. The cancel targeted a
      placement broker never accepted.

    The workflow is bus-agnostic: it depends on a plain
    [_ -> unit] port, not on any specific transport. *)

module Order_cancelled :
    module type of Broker_integration_events.Order_cancelled_integration_event

module type Command_log = Broker_store.Order_command_log.S

val execute :
  broker:Broker.client ->
  command_log:(module Command_log with type t = 'log) ->
  command_log_handle:'log ->
  now_ts:(unit -> int64) ->
  publish_order_cancelled:(Order_cancelled.t -> unit) ->
  Cancel_pending_order_command.t ->
  (unit, Cancel_pending_order_command_handler.handle_error) Rop.t
