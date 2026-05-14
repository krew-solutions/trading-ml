(** Command pipeline for {!Apply_bar_command.t}.

    Composes the parse/match/store step from
    {!Apply_bar_command_handler.handle} with per-fill domain-event
    publication. Each {!Pending_order.t} that the bar fills emits a
    {!Paper_broker.Order.Events.Fill_observed.t} domain event,
    translated by the {!Paper_broker_domain_event_handlers.Publish_integration_event_on_fill_observed}
    handler into an outbound integration event carrying the
    pending order's own [correlation_id] and [reservation_id].

    The bar command itself carries no correlation_id: bars are
    market data, not part of a single saga. The per-fill
    correlation tokens come from the originating
    {!Submit_order_command.t} preserved in the
    {!Pending_order.t}. *)

module Order_filled :
    module type of Paper_broker_integration_events.Order_filled_integration_event

module type Store = Order_store.S

val execute :
  store:(module Store with type t = 'store) ->
  store_handle:'store ->
  slippage_bps:Paper_broker.Slippage.Values.Slippage_bps.t ->
  fee_rate:Paper_broker.Fee.Values.Fee_rate.t ->
  next_exec_id:(unit -> string) ->
  publish_order_filled:(Order_filled.t -> unit) ->
  Apply_bar_command.t ->
  (unit, Apply_bar_command_handler.handle_error) Rop.t
