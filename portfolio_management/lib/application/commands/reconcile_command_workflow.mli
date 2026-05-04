(** ROP pipeline for {!Reconcile_command.t}: runs the handler and
    publishes a {!Trade_intents_planned_integration_event.t} on the
    success path. *)

module Trade_intents_planned =
  Portfolio_management_integration_events.Trade_intents_planned_integration_event

val execute :
  target_portfolio_for:
    (Portfolio_management.Common.Book_id.t ->
    Portfolio_management.Target_portfolio.t option) ->
  actual_portfolio_for:
    (Portfolio_management.Common.Book_id.t ->
    Portfolio_management.Actual_portfolio.t option) ->
  publish_trade_intents_planned:(Trade_intents_planned.t -> unit) ->
  Reconcile_command.t ->
  (unit, Reconcile_command_handler.handle_error) Rop.t
