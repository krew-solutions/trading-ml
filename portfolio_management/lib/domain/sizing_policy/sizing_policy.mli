(** Sizing policy: pure function that converts a dimensionless
    {!Construction_intent.t} into a sized
    {!Target_proposal.t} given the book's available capital,
    a per-instrument mark price provider, and an optional
    per-instrument volatility provider.

    Sizing is the {b construction} half of the construction →
    clipping pipeline: it produces target quantities; downstream
    {!Risk_policy.clip} reduces them to fit absolute caps.
    Sizing policies therefore MUST NOT consult risk limits — that
    concern lives strictly in [clip].

    A policy operates on the whole intent at once, so multi-leg
    sizings preserving inter-leg invariants (β-parity for pairs,
    basket weights, vol parity) are expressible within the
    abstraction. Single-leg intents degenerate naturally.

    Realised target_qty MUST carry the originating intent's
    {!Coupling.t} on every leg when the intent is {!Coupled} —
    this is how downstream clip knows to scale the group
    proportionally rather than per-leg. The conventional
    re-export pattern below makes [Equity_proportional] the
    canonical default; future implementations
    ([Volatility_target], [Inverse_vol], [Kelly_fraction], etc.)
    plug in as additional modules under this namespace. *)

module type S = sig
  type config

  val name : string
  (** Stable, opaque label identifying this policy. Appears in
      {!Target_proposal.t}'s [source] for audit. *)

  val size :
    config ->
    book_equity:Decimal.t ->
    mark:(Core.Instrument.t -> Decimal.t) ->
    volatility:(Core.Instrument.t -> Decimal.t option) ->
    Common.Construction_intent.t ->
    Common.Target_proposal.t
  (** [size cfg ~book_equity ~mark ~volatility intent] converts
      the intent into a {!Target_proposal.t}.

      Contract:
      - the output's [book_id] equals the input intent's
        [book_id];
      - the output's [positions] has exactly one entry per
        non-{!Direction.Flat} leg of the intent and is sorted
        by [Core.Instrument.compare];
      - every output leg's [coupling] matches the intent's
        coupling — [None] for {!Scalar}, [Some _] for
        {!Coupled} (every leg carries the same value);
      - a zero [book_equity] (or non-positive [mark]) yields a
        leg with [target_qty = 0] rather than a partial output;
        Why3 invariant: [size] is total in the formal sense. *)
end

module Equity_proportional : S with type config = unit
(** Default sizing: per-leg [target_qty = book_equity × weight
    / mark]. For {!Scalar} intents the [weight] is
    [direction × strength]; for {!Coupled} it is the leg's
    pre-normalised signed weight. Preserves ratios by
    construction in the {!Coupled} case. *)

module Volatility_target : S with type config = Volatility_target.config
(** Vol-target overlay: scale per-leg notional so that
    [|qty| × mark × σ̂] matches the book's annualised volatility
    budget. Refuses to size (qty = 0) when the volatility
    provider has no reading for an instrument — operator picked
    this policy because vol awareness is the point; pretending
    to size without it would silently degrade to fixed-fractional. *)
