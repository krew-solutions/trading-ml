(** Shared builder for a pair-trading {!Construction_intent.Coupled}.

    A pair-trading policy — static or adaptive — produces the same
    structural intent shape: two legs of the pair with signed,
    β-weighted, dimensionless weights, tied together by a single
    {!Coupling.t} so downstream {!Risk_policy.clip} preserves the
    β-ratio under per-instrument caps.

    Weights, by direction:
    - [Flat]         → both legs at weight 0.
    - [Long_spread]  → A-leg at [+1/(1+β)], B-leg at [-β/(1+β)].
    - [Short_spread] → A-leg at [-1/(1+β)], B-leg at [+β/(1+β)].

    [Σ |weight| = 1] when not flat (full book exposure at the
    sizing-policy step), and the sign convention matches the
    {!Pair.t}-spread definition [log_a − β · log_b]:

    - a positive spread (high A relative to β · B) is shorted,
      so {!Short_spread} sells A and buys β units of B;
    - a negative spread is longed, so {!Long_spread} buys A and
      sells β units of B.

    The β argument is supplied as [float] rather than
    {!Hedge_ratio.t}. Callers with a guaranteed-positive hedge
    ratio (e.g. {!Pair_mean_reversion}) pass
    [Decimal.to_float (Hedge_ratio.to_decimal hr)]; callers
    whose β is a posterior estimate (e.g. {!Pair_kalman_mean_reversion})
    pass [posterior.mean_beta] directly. The builder clamps
    [β < 1e-6] to [1e-6] before converting to {!Decimal.t} so
    a transient near-zero posterior cannot raise inside
    {!Hedge_ratio} or produce a zero-denominator division. *)

val build :
  pair:Pair.t ->
  book_id:Book_id.t ->
  direction:Pair_direction.t ->
  beta:float ->
  source:Source.t ->
  observed_at:int64 ->
  coupling_source:string ->
  Construction_intent.t
(** [build ~pair ~book_id ~direction ~beta ~source ~observed_at
    ~coupling_source] returns a {!Construction_intent.Coupled}
    realising [direction] for [pair] with the supplied β. The
    [coupling_source] argument is the policy-stable label that
    distinguishes two coupling groups generated at the same
    [observed_at] (e.g. ["pair_mean_reversion"] vs
    ["pair_kalman_mean_reversion"] on the same pair). *)
