(** Command pipeline for {!Submit_order_command.t}.

    Composes the parse/build/persist step from
    {!Submit_order_command_handler.handle} with two side effects:
    - records the submit's [correlation_id] in the
      {!Paper_broker_store.Order_command_log.S} (so downstream
      events that lack their own correlation context — notably
      [Trade_executed] emitted from per-bar matching — can recover
      it).
    - publishes the
      {!Paper_broker_integration_events.Order_accepted_integration_event.t}
      via the DEH.

    On validation failure, publishes a
    {!Paper_broker_integration_events.Order_rejected_integration_event.t}
    so the originating saga can compensate. *)

module Order_accepted :
    module type of Paper_broker_integration_events.Order_accepted_integration_event

module Order_rejected :
    module type of Paper_broker_integration_events.Order_rejected_integration_event

module type Store = Paper_broker_store.Order_store.S
module type Command_log = Paper_broker_store.Order_command_log.S

val execute :
  store:(module Store with type t = 'store) ->
  store_handle:'store ->
  command_log:(module Command_log with type t = 'log) ->
  command_log_handle:'log ->
  next_order_id:(unit -> string) ->
  now_ts:(unit -> int64) ->
  placed_after_ts:(Core.Instrument.t -> int64) ->
  publish_order_accepted:(Order_accepted.t -> unit) ->
  publish_order_rejected:(Order_rejected.t -> unit) ->
  Submit_order_command.t ->
  (unit, Submit_order_command_handler.handle_error) Rop.t
