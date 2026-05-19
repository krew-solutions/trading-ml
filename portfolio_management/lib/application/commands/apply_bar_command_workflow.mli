(** ROP pipeline for {!Apply_bar_command.t}.

    Composes {!Apply_bar_command_handler.handle} with the
    success-path projection that feeds every emitted
    {!Construction_intent.t} into the unified construction →
    sizing → clipping pipeline. From there the target is set on
    the book and a {!Target_portfolio_updated_integration_event}
    is published.

    Symmetric with
    {!Portfolio_management_domain_event_handlers.Dispatch_construction_intent_on_alpha_direction_changed}:
    both paths converge on the same downstream handler
    ({!Build_target_on_construction_intent.handle}); the
    construction policy alone decides {b what} the intent looks
    like (Scalar for alpha, Coupled for pair-MR), the unified
    handler decides {b how} it becomes a sized clipped target. *)

module Target_portfolio_updated =
  Portfolio_management_integration_events.Target_portfolio_updated_integration_event

val execute :
  pair_mr_states_for:
    (Core.Instrument.t ->
    Portfolio_management.Pair_mean_reversion.state ref list) ->
  risk_config_for:
    (Portfolio_management.Common.Book_id.t ->
    Portfolio_management.Risk_config.t option) ->
  total_equity_for:(Portfolio_management.Common.Book_id.t -> Decimal.t) ->
  mark_for:
    (Portfolio_management.Common.Book_id.t ->
    Core.Instrument.t ->
    Decimal.t) ->
  volatility_for:(Core.Instrument.t -> Decimal.t option) ->
  sizing_for:
    (Portfolio_management.Common.Book_id.t ->
    Portfolio_management_domain_event_handlers
    .Build_target_on_construction_intent
    .sizing_fn) ->
  target_portfolio_for:
    (Portfolio_management.Common.Book_id.t ->
    Portfolio_management.Target_portfolio.t ref) ->
  publish_target_portfolio_updated:(Target_portfolio_updated.t -> unit) ->
  Apply_bar_command.t ->
  (unit, Apply_bar_command_handler.handle_error) Rop.t
