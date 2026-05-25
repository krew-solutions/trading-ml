(** Command pipeline for {!Apply_bar_command.t}.

    Composes the parse/match/store step from
    {!Apply_bar_command_handler.handle} with per-fill domain-event
    publication.

    Each {!Paper_broker.Order.t} that the bar fills emits a
    {!Paper_broker.Order.Events.Trade_executed.t}. The bar itself
    carries no [correlation_id], so for each fill the workflow
    recovers the originating-Submit's [correlation_id] from the
    {!Paper_broker_store.Order_command_log.S} (see *Process
    correlation is not aggregate state* in
    [docs/architecture/hexagonal-architecture.md]) and forwards it
    to the IE-emitting DEH. *)

module Trade_executed :
    module type of Paper_broker_integration_events.Trade_executed_integration_event

module type Store = Paper_broker_store.Order_store.S
module type Command_log = Paper_broker_store.Order_command_log.S

val execute :
  store:(module Store with type t = 'store) ->
  store_handle:'store ->
  command_log:(module Command_log with type t = 'log) ->
  command_log_handle:'log ->
  slippage_bps:Paper_broker.Slippage.Values.Slippage_bps.t ->
  fee_rate:Paper_broker.Fee.Values.Fee_rate.t ->
  participation_rate:Paper_broker.Matching.Values.Participation_rate.t option ->
  next_trade_id:(unit -> string) ->
  publish_trade_executed:(Trade_executed.t -> unit) ->
  Apply_bar_command.t ->
  (unit, Apply_bar_command_handler.handle_error) Rop.t
