(** Domain-event handler for
    {!Portfolio_management.Alpha_view.Events.Direction_changed}.

    Fans out the alpha-direction flip to every book subscribed to the
    [(alpha_source_id, instrument)] pair: for each subscriber, sizes
    a single-leg target proposal (signed by direction, scaled by
    [strength × notional_cap / price]) and applies it to that book's
    target_portfolio. The resulting [Target_set] domain event is then
    routed through the existing outbound IE publisher.

    Three injected ports stand in for as-yet-unbuilt domain
    aggregates:
    - [subscribers_for] — placeholder for [Alpha_subscription]
      registry;
    - [notional_cap_for] — placeholder for per-book risk-config
      aggregate;
    - [target_portfolio_for] — registry of target_portfolio refs
      kept by composition root, same shape as in existing flows. *)

module Direction_changed = Portfolio_management.Alpha_view.Events.Direction_changed

module Target_portfolio_updated =
  Portfolio_management_integration_events.Target_portfolio_updated_integration_event

val handle :
  subscribers_for:
    (alpha_source_id:Portfolio_management.Common.Alpha_source_id.t ->
    instrument:Core.Instrument.t ->
    Portfolio_management.Common.Book_id.t list) ->
  notional_cap_for:(Portfolio_management.Common.Book_id.t -> Decimal.t) ->
  target_portfolio_for:
    (Portfolio_management.Common.Book_id.t -> Portfolio_management.Target_portfolio.t ref) ->
  publish_target_portfolio_updated:(Target_portfolio_updated.t -> unit) ->
  Direction_changed.t ->
  unit
