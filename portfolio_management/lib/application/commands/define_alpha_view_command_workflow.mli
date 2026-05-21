(** ROP pipeline for {!Define_alpha_view_command.t}.

    Composes {!Define_alpha_view_command_handler.handle} with the
    success-path domain-event handler that projects the
    [Direction_changed] event to a {!Construction_intent.Scalar}
    for each subscribing book and feeds it through the unified
    construction → sizing → clipping pipeline.

    No outbound integration event is emitted directly here — the
    target-update IE is published by the existing
    {!Publish_integration_event_on_target_set} domain-event
    handler, invoked transitively by the unified handler. *)

module Direction_changed = Portfolio_management.Alpha_view.Events.Direction_changed

module Target_portfolio_updated =
  Portfolio_management_integration_events.Target_portfolio_updated_integration_event

val execute :
  alpha_view_for:
    (alpha_source_id:Portfolio_management.Common.Alpha_source_id.t ->
    instrument:Core.Instrument.t ->
    Portfolio_management.Alpha_view.t ref) ->
  subscribers_for:
    (alpha_source_id:Portfolio_management.Common.Alpha_source_id.t ->
    instrument:Core.Instrument.t ->
    Portfolio_management.Common.Book_id.t list) ->
  risk_config_for:
    (Portfolio_management.Common.Book_id.t -> Portfolio_management.Risk_config.t option) ->
  total_equity_for:(Portfolio_management.Common.Book_id.t -> Decimal.t) ->
  mark_for:(Portfolio_management.Common.Book_id.t -> Core.Instrument.t -> Decimal.t) ->
  volatility_for:(Core.Instrument.t -> Decimal.t option) ->
  sizing_for:
    (Portfolio_management.Common.Book_id.t ->
    Portfolio_management_domain_event_handlers.Build_target_on_construction_intent
    .sizing_fn) ->
  target_portfolio_for:
    (Portfolio_management.Common.Book_id.t -> Portfolio_management.Target_portfolio.t ref) ->
  publish_target_portfolio_updated:(Target_portfolio_updated.t -> unit) ->
  Define_alpha_view_command.t ->
  (unit, Define_alpha_view_command_handler.handle_error) Rop.t
