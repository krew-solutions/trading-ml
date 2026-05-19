(** Volatility-target sizing: scale per-leg notional so that
    [|qty| × mark × σ̂] matches a configured per-book annualised
    volatility budget.

    Per-leg quantity:
      qty = book_equity × weight × (target_vol / σ̂_instrument)
            / mark

    Rationale: in a vol-target overlay the operator declares
    the {b risk} budget (target annualised volatility) rather
    than the {b capital} budget, and the policy adapts position
    sizes so that book volatility stays approximately on
    target as instrument volatility drifts. Low-vol instruments
    get larger positions, high-vol smaller — the overall
    risk envelope is bounded by the operator's choice rather
    than by per-instrument notional caps alone.

    Refusal-to-size policy: when the volatility provider does
    not yet have a reading for an instrument (warmup,
    missing feed) the leg gets [target_qty = 0]. This is a
    {b deliberate sentinel}, not a fallback: a vol-target
    policy that pretends to size without vol information would
    silently behave like fixed-fractional, which is exactly the
    opposite of what an operator picking this policy asked for.

    Edges, by design:
    - non-positive [mark] for an instrument → leg's qty is 0;
    - zero [book_equity] → every leg's qty is 0;
    - {!Volatility.t} zero for an instrument with non-zero
      target_vol → leg's qty is 0 (would otherwise be infinite);
    - {!Direction.Flat} scalar intent → singleton list with
      qty 0;
    - [Coupled] intent: the {!Coupling.t} on the input
      propagates to every output leg; clip downstream will
      scale the group as a unit. *)

type config = { target_annual_vol : Decimal.t }
(** [target_annual_vol] is the per-book annualised volatility
    target, expressed as a fractional {!Decimal.t} (e.g.
    [0.10] for 10%). Built by the application layer from the
    wire-side string. *)

val name : string
(** ["volatility_target"]. *)

val size :
  config ->
  book_equity:Decimal.t ->
  mark:(Core.Instrument.t -> Decimal.t) ->
  volatility:(Core.Instrument.t -> Decimal.t option) ->
  Common.Construction_intent.t ->
  Common.Target_proposal.t
