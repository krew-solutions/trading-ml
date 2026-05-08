(** Pure pre-trade gate. Mirrors the original [Engine.Risk.check]
    semantics, but operates on the BC-local {!Risk_view.t} rather
    than {!Account.Portfolio.t} so the assessment stays inside this
    BC.

    Three sequential checks against a candidate trade leg:

    1. [min_cash_buffer] — post-reservation
       [available_cash − notional ≥ min_cash_buffer] (sign of
       [notional] depends on side);
    2. [max_gross_exposure] —
       [Σ |position_qty| × mark + new_notional ≤ max_gross_exposure];
    3. [max_leverage] — [gross_exposure / equity ≤ max_leverage].

    Each check fires hard-veto on failure. Equity is computed from the
    view's cash plus marked-to-market positions. [mark] is a closure
    supplied by the caller (typically a Hashtbl populated from
    [Bar_updated] integration events); when an instrument has no quote
    the position's [avg_price] is used as a fallback. *)

type outcome = Approve of Decimal.t | Reject of string

val assess :
  view:Risk_view.t ->
  limits:Risk_limits.t ->
  side:Core.Side.t ->
  instrument:Core.Instrument.t ->
  quantity:Decimal.t ->
  price:Decimal.t ->
  mark:(Core.Instrument.t -> Decimal.t option) ->
  outcome
(** [assess ~view ~limits ~side ~instrument ~quantity ~price ~mark]
    returns [Approve quantity] when every check passes (the leg is
    accepted at full size — the gate does not down-scale, only vetoes;
    construction-time soft clipping lives in
    {!Portfolio_management.Risk_policy}); otherwise [Reject reason]. *)
