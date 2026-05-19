(** Per-book risk configuration aggregate. Owns the parameters
    that bound a book's construction-time behaviour.

    Four concepts kept apart deliberately:

    - [risk_budget_fraction] — the {b sizing} primitive: the
      share of total account equity allocated to this book. A
      book with [risk_budget_fraction = 0.3] sizes positions
      against [0.3 × total_equity]. Operator-level capital
      allocation in [\[0, 1\]].
    - [limits] — the {b clipping} primitive: absolute caps
      (per-instrument notional, gross exposure) the
      construction output must respect regardless of sizing.
      Regulatory / prime-broker constraints, NOT functions of
      equity.
    - [construction_source] — exactly one
      {!Common.Source.t} permitted to publish targets to this
      book. "One construction source per book" as a
      structural invariant.
    - [sizing_policy] — which {!Sizing_policy.S}
      implementation runs on this book. Different books on the
      same installation can pick different policies
      ({!Equity_proportional} for one, {!Volatility_target}
      with its own target for another); per-book divergence
      is the whole point of the pluggable abstraction. *)

type t

val make :
  book_id:Common.Book_id.t ->
  risk_budget_fraction:Decimal.t ->
  limits:Risk.Values.Risk_limits.t ->
  construction_source:Common.Source.t ->
  sizing_policy:Common.Sizing_policy_choice.t ->
  t
(** Raises [Invalid_argument] when [risk_budget_fraction] is
    outside [\[0, 1\]] or when
    [sizing_policy = Volatility_target { target_annual_vol }]
    with [target_annual_vol] strictly negative. [limits] is
    already validated by {!Risk.Values.Risk_limits.make}. *)

val book_id : t -> Common.Book_id.t
val risk_budget_fraction : t -> Decimal.t
val limits : t -> Risk.Values.Risk_limits.t
val construction_source : t -> Common.Source.t
val sizing_policy : t -> Common.Sizing_policy_choice.t

val book_equity : t -> total_equity:Decimal.t -> Decimal.t
(** [book_equity t ~total_equity] is the equity slice a sizing
    policy should treat as the book's capital, i.e.
    [risk_budget_fraction × total_equity]. *)

val authorises : t -> Common.Source.t -> bool
(** [authorises t s] is [true] iff [s] equals the
    [construction_source] this aggregate permits — the
    one-source-per-book invariant in predicate form. *)
