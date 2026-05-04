(** Construction-time risk clipping. Reduces leg target_qty values so
    the proposal stays within the configured limits. Pure
    transformation; no events.

    Two clipping passes, applied in order:

    1. Per-instrument: each leg's notional [|target_qty| × mark] is
       capped at [limits.max_per_instrument_notional]. The clipped
       quantity preserves sign.
    2. Gross-exposure: if the post-step-1 sum of leg notionals
       exceeds [limits.max_gross_exposure], every leg is scaled by a
       single common factor so the gross sum equals the cap. This
       preserves the *ratios* between legs — important for hedge-
       symmetric target like pair_mean_reversion's
       [+N a, −β·N b] (the β-relationship survives clipping). *)

val clip :
  limits:Values.Risk_limits.t ->
  mark:(Core.Instrument.t -> Decimal.t) ->
  Common.Target_proposal.t ->
  Common.Target_proposal.t
(** Pure: same input → same output. The mark callback is total
    (returns [Decimal.zero] for unknown instruments) — the caller is
    responsible for providing prices for every instrument in the
    proposal. *)
