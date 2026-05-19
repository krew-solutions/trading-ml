(** Unified domain-event handler that converts a
    {!Portfolio_management.Common.Construction_intent.t} into a
    {!Portfolio_management.Target_portfolio.Events.Target_set.t}
    via the construction → sizing → clipping pipeline.

    Every PM construction policy — alpha-driven single-asset,
    pair-mean-reversion, future basket / factor / risk-parity —
    funnels through this single handler. The discriminator is the
    intent's variant; the handler dispatches sizing accordingly.

    Pipeline:
    1. Resolve per-book {!Risk_config.t}. If the book has no
       configuration the handler is a silent no-op (defensive;
       composition is responsible for keeping registries aligned).
    2. Enforce the one-source-per-book invariant via
       {!Risk_config.authorises}. Intents whose source does not
       match the configured construction_source are dropped.
    3. Compute [book_equity = total_equity ×
       risk_budget_fraction] via {!Risk_config.book_equity}.
    4. Hand the intent to the per-book sizing function (provided
       by [sizing_for]).
    5. Apply {!Risk_policy.clip} with the book's limits and
       per-instrument marks.
    6. Apply the clipped proposal to the book's
       {!Target_portfolio.t}; publish the resulting
       {!Target_set.t} via the existing publication handler. *)

module Risk_config = Portfolio_management.Risk_config
module Common = Portfolio_management.Common
module Target_portfolio = Portfolio_management.Target_portfolio

type sizing_fn =
  book_equity:Decimal.t ->
  mark:(Core.Instrument.t -> Decimal.t) ->
  volatility:(Core.Instrument.t -> Decimal.t option) ->
  Common.Construction_intent.t ->
  Common.Target_proposal.t
(** Closed-over-config sizing function for one book; produced by
    the factory per the book's selected
    {!Portfolio_management.Sizing_policy.S} implementation. *)

val handle :
  risk_config_for:(Common.Book_id.t -> Risk_config.t option) ->
  total_equity_for:(Common.Book_id.t -> Decimal.t) ->
  mark_for:(Common.Book_id.t -> Core.Instrument.t -> Decimal.t) ->
  volatility_for:(Core.Instrument.t -> Decimal.t option) ->
  sizing_for:(Common.Book_id.t -> sizing_fn) ->
  target_portfolio_for:(Common.Book_id.t -> Target_portfolio.t ref) ->
  publish_target_portfolio_updated:
    (Portfolio_management_integration_events.Target_portfolio_updated_integration_event.t ->
    unit) ->
  Common.Construction_intent.t ->
  unit
