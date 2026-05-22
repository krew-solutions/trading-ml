# 0024. Equity-anchored sizing with explicit Risk_config

**Status**: Accepted
**Date**: 2026-05-19

## Context

Portfolio Management runs two construction pathways: alpha-driven
single-asset (a directional view + dimensionless conviction) and
pair_mean_reversion (a β-hedged two-leg construction). Until this
ADR they shared no upstream input shape, no sizing logic, no
clipping invocation. Concretely:

- The alpha-driven handler sized via
  `qty = strength × notional_cap_for(book) / price`, where
  `notional_cap_for` was a `factory.ml` placeholder hard-coded
  to 100 000 across all books — a TODO marker, not a load-
  bearing decision.
- The alpha-driven handler **did not invoke `Risk_policy.clip`**;
  alpha-side targets bypassed all risk caps.
- `pair_mean_reversion.on_bar` produced an already-sized
  `Target_proposal` from its own `config.notional`, conflating
  the construction decision (long/short spread, β, units) with
  the sizing decision (notional / mark).
- `Risk_policy.clip_per_instrument` clipped each leg
  independently, silently breaking the β-ratio of pair legs
  whenever one leg of a pair exceeded the per-instrument cap
  and its peer did not — a latent invariant break in
  pair-mean-reversion already in production code.
- `domain/sizing.ml` (`from_strength`) was an orphan: migrated
  out of `Strategy.Engine.Risk` during M3 but never wired.

This ADR settles the construction-time arithmetic and risk
discipline for PM with a single decomposition all current and
future construction policies share.

## Decision

Adopt the construction → sizing → clipping decomposition
canonical in portfolio-management literature (Grinold-Kahn,
Pedersen). Concretely:

1. **Construction policies emit dimensionless intents**, not
   sized proposals. The `Construction_intent.t` sum type has
   two variants:
   - `Scalar { direction; strength; ... }` for single-asset
     alpha-driven decisions;
   - `Coupled { legs; coupling; ... }` for multi-leg policies
     (pair, future basket / factor / risk-parity). The
     `Σ |weight| ≤ 1` invariant is enforced by the smart
     constructor; a shared `Coupling.t` ties the legs together.

2. **Sizing is a pluggable pure function from intent to
   proposal**, captured by `Sizing_policy.S`. The single
   implementation today is `Equity_proportional`:
   `target_qty = book_equity × weight / mark`. Sentinel
   behaviour on edges: non-positive `mark`, zero
   `book_equity`, or `Direction.Flat` collapses the leg to
   `target_qty = 0` rather than raising — so a stale mark
   cache cannot stop the rest of the proposal.

3. **Capital is equity-anchored, not notional-cap-anchored.**
   `book_equity` is computed as `Risk_config.risk_budget_fraction
   × total_equity_for(book)`. The
   `risk_budget_fraction ∈ [0, 1]` is an operator-level capital
   allocation between books — explicit and configurable,
   replacing the implicit `notional_cap_for` placeholder.

4. **Clipping is coupling-aware.** `Risk_policy.clip` now
   distinguishes independent legs (`coupling = None`) from
   members of a coupling group (`coupling = Some c`). In the
   per-instrument pass, legs of one group are scaled by a
   single common factor sufficient to bring the worst-
   offending leg under the cap; the gross-exposure pass
   already preserved ratios across all legs. β-symmetry and
   basket weights survive clipping by construction, not by
   accident.

5. **Per-book risk configuration lives in `Risk_config`.**
   The aggregate carries:
   - `risk_budget_fraction` (sizing primitive);
   - `Risk_limits.t` (clipping primitive);
   - `construction_source` (the single `Source.t` permitted to
     publish targets to this book — "one construction source
     per book" as a structural invariant, formalised in the
     aggregate, enforced via `Risk_config.authorises` in the
     unified handler).

6. **A unified handler funnels every intent through the same
   pipeline.**
   `Build_target_on_construction_intent.handle` does:
   resolve `Risk_config` → enforce source authorisation →
   compute `book_equity` → call per-book `Sizing_policy.size` →
   `Risk_policy.clip` → `Target_portfolio.apply_proposal` →
   publish `Target_set`. Both `Direction_changed` (alpha) and
   pair-MR's `on_bar` output project to a
   `Construction_intent.t` and feed this single handler.

7. **`domain/sizing.ml` is removed.** The migrated-but-unwired
   scaffold from M3 has no place in the new decomposition.
   Equity-aware sizing now lives in `Equity_proportional` and
   future variations (`Volatility_target`, `Kelly_fraction`,
   `Inverse_vol`, `Risk_parity_legs`) plug in as additional
   modules under `domain/sizing_policy/` against the same
   `Sizing_policy.S` module type.

## Alternatives considered

### A. Keep notional-cap as the sizing anchor

Retain `notional_cap_for(book)` as the cap-as-budget primitive.
Construction policies size against a configured cap; equity
does not enter sizing.

Rejected because:

- It conflates two concepts that belong apart: the
  capital-allocation knob (operator decides how much of the
  book to use) and the regulatory/operational cap (how much
  the book is allowed to use). Treating them as one creates
  the placeholder hell `notional_cap_for` already
  demonstrates: per-book hardcoded number with a TODO
  acknowledging it should be an aggregate.
- It forfeits compounding. A book that grows from 100k to 200k
  AUM stays sized as if it were still 100k until someone hand-
  edits config — operationally fragile in a multi-book
  installation.
- It is at odds with the academic and industry canon
  (Markowitz, Grinold-Kahn, Pedersen, BlackRock Aladdin) where
  weights against equity is the fundamental language and
  absolute caps are the regulatory ceiling.
- Future equity-aware policies (vol-target overlays,
  Kelly-fraction sizing, fixed-fractional bet sizing) are
  trivially expressible against equity-anchored decomposition;
  they would require ad-hoc retrofitting under notional-anchor.

### B. Collapse alpha and construction into a single weight-vector
abstraction (qstrader-style)

Have every policy — alpha-driven, pair, basket — return
`dict[Asset, weight]`. A single `OrderSizer` materialises the
dict into quantities using equity.

Rejected because:

- It erases first-class domain expressiveness. A pair is not a
  weight dict that happens to have two entries; it carries a
  β-invariant whose load-bearing nature must be visible to
  every downstream stage that might break it. Under
  weight-dict the invariant survives only if `_normalise_weights`
  happens to use the right formula — incidental, not
  contractual.
- It is a structural transcription of QuantStart's educational
  framework, designed under a single-asset assumption with
  pairs prosecuted in by community forks. Our architecture is
  strictly richer (first-class `Pair_mean_reversion` aggregate
  with explicit `Hedge_ratio`, formal `Coupling` tag,
  Why3-verified arithmetic); copying the flattened contract
  downgrades our decomposition to the level of the reference.

The sum-type `Construction_intent` preserves the
structural distinction between scalar and coupled origins while
still unifying downstream — every variant feeds the same
handler. This is the unification at the right level of
abstraction.

### C. Per-policy anchor choice (some policies equity-anchored,
some notional-anchored)

Allow `Sizing_policy.S` implementations to differ on what they
read: `Equity_proportional` reads `book_equity`, a
hypothetical `Notional_fixed` reads a per-book configured cap.

Rejected for today because there is no current driver — every
present policy reads equity. Holding both modalities open in
the abstraction without an implementation that needs it is a
premature-abstraction smell (YAGNI). If a future driver
appears, `Sizing_policy.S` is wide enough to accommodate
(the [config] type is per-implementation): a `Notional_fixed`
module can take a notional cap in its config and produce a
proposal independent of equity, sitting alongside
`Equity_proportional`. The decomposition does not preclude C;
it just does not pre-build for it.

## Consequences

**Easier:**

- A new construction policy (basket, factor, vol-target,
  risk-parity) plugs in as a `Construction_intent.t`-emitting
  module; everything downstream is reused.
- A new sizing variant (`Volatility_target`, `Kelly_fraction`)
  plugs in as a `Sizing_policy.S` implementation; the unified
  handler picks it up via the per-book registry without
  changes to construction or clipping.
- β-hedge symmetry and basket weights are preserved by
  construction through `Risk_policy.clip` rather than by
  accident; the formal `coupling_ratio_preserved` invariant in
  `risk_policy.mlw` makes the property auditable.
- Capital allocation between books is explicit
  (`risk_budget_fraction`); compounding works automatically as
  equity changes.
- The one-source-per-book invariant is a structural property
  of `Risk_config`, formalised as a Why3 predicate
  (`authorises`) and enforced in the unified handler. Conflict
  detection is by type, not by convention.

**Harder:**

- Tests and operators must now configure three things per book
  (a `Risk_config`, a `total_equity`, and a per-instrument
  mark) where previously only a `notional_cap` was needed.
  This is a deliberate exposure of structure that had been
  hidden inside one placeholder.
- The pipeline now requires real `mark_for` and
  `total_equity_for` ports. Factory stubs return zero today,
  which the sizing sentinels collapse to zero-qty — the
  pipeline is observable but inert until those ports are
  populated. A follow-up wires PM to the broker bar feed
  (mirroring ADR 0023's EM subscription) and to an
  `Account.equity_view`.
- A future requirement for explicit notional-cap-anchored
  sizing on a specific book requires a new `Sizing_policy.S`
  implementation rather than a config knob on
  `Equity_proportional`.

**To watch for:**

- `volatility_provider` is a stub returning `None` for every
  instrument. Any policy that consumes volatility must refuse
  to size until this provider is backed by a real source
  (rolling stdev computed in PM, or a `Volatility` IE from a
  future Indicators BC).
- The unified handler is a silent no-op for books without a
  `Risk_config`. The empty `risk_configs` registry in
  `factory.ml` means alpha and pair-MR both fall through
  today; the integration is observable but inert until a
  configuration command lands. This is intentional
  scaffolding, not a bug.
- The `Construction_intent.Coupled` invariants enforce
  `Σ |w| ≤ 1`. A policy that wants leverage (`Σ |w| > 1`)
  cannot express it through this VO; that constraint becomes
  a separate per-policy or per-book modifier when first
  needed.

## References

- ADR 0009 — Portfolio Management bounded context; this ADR
  refines its risk-as-policy / risk-as-gatekeeper split.
- ADR 0010 — Alpha-mind vs bracket-exit projection; the
  `(direction, strength)` shape from Strategy projects to
  `Construction_intent.Scalar`.
- ADR 0011 — Risk evacuation and pre_trade_risk; this ADR's
  `Risk_policy.clip` is the construction-time soft cap,
  distinct from pre_trade_risk's hard gates.
- ADR 0023 — Broker bar feed into EM ports; the pattern PM
  will follow when `mark_for` is backed by the bar feed.
- `portfolio_management/lib/domain/common/construction_intent.{ml,mli,mlw}` —
  sum-type intent VO.
- `portfolio_management/lib/domain/common/coupling.{ml,mli,mlw}` —
  opaque coupling identifier.
- `portfolio_management/lib/domain/sizing_policy/` —
  module type S + `Equity_proportional` implementation.
- `portfolio_management/lib/domain/risk_config/risk_config.{ml,mli,mlw}` —
  per-book aggregate with `risk_budget_fraction`, `limits`,
  `construction_source`.
- `portfolio_management/lib/domain/risk/risk_policy.{ml,mli,mlw}` —
  coupling-aware clip.
- `portfolio_management/lib/application/domain_event_handlers/build_target_on_construction_intent.{ml,mli}` —
  the unified pipeline.
