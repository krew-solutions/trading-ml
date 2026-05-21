(** Domain-event handler for
    {!Portfolio_management.Alpha_view.Events.Direction_changed}.

    Fans the alpha-direction flip out to every subscribing book:
    for each subscriber it projects the event to a
    {!Common.Construction_intent.Scalar} (via the event's own
    [to_construction_intent] domain function) and feeds it to
    {!Build_target_on_construction_intent.handle}. From there
    the unified construction → sizing → clipping pipeline runs.

    Injected ports mirror those of the unified handler; the only
    handler-local concern is the subscriber fan-out itself
    ([subscribers_for]). *)

module Direction_changed = Portfolio_management.Alpha_view.Events.Direction_changed

module Target_portfolio_updated =
  Portfolio_management_integration_events.Target_portfolio_updated_integration_event

val handle :
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
    Build_target_on_construction_intent.sizing_fn) ->
  target_portfolio_for:
    (Portfolio_management.Common.Book_id.t -> Portfolio_management.Target_portfolio.t ref) ->
  publish_target_portfolio_updated:(Target_portfolio_updated.t -> unit) ->
  Direction_changed.t ->
  unit
