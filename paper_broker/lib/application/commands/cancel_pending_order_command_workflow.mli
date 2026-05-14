(** Command pipeline for {!Cancel_pending_order_command.t}.

    Composes the store-side cancel transition from
    {!Cancel_pending_order_command_handler.handle} with the
    domain-event publication from
    {!Paper_broker_domain_event_handlers.Publish_integration_event_on_order_cancelled.handle}.

    The outbound integration event echoes the cancel command's
    own [correlation_id] (the cancellation saga's instance id) and
    the persisted {!Pending_order.t}'s [reservation_id] so Account
    can release the remaining reserved cash/position. *)

module Order_cancelled :
    module type of Paper_broker_integration_events.Order_cancelled_integration_event

module type Store = Order_store.S

val execute :
  store:(module Store with type t = 'store) ->
  store_handle:'store ->
  now_ts:(unit -> int64) ->
  publish_order_cancelled:(Order_cancelled.t -> unit) ->
  Cancel_pending_order_command.t ->
  (unit, Cancel_pending_order_command_handler.handle_error) Rop.t
