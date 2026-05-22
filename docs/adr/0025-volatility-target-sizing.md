# 0025. Volatility-target sizing as the first vol-aware policy

**Status**: Accepted
**Date**: 2026-05-19

## Context

ADR 0024 introduced the construction → sizing → clipping
decomposition with `Sizing_policy.S` as a deliberately
pluggable abstraction and `Equity_proportional` as its sole
day-one implementation. The same ADR flagged
`Volatility_target` / `Kelly` / `Inverse_vol` / `Risk_parity` as
designed extension points that would land "each its own
follow-up ADR".

This is that follow-up for `Volatility_target`. It records the
decisions taken when materialising the extension point: how the
volatility provider is wired, how the per-book sizing choice
flows from operator wire-format down into the unified handler,
and what refusal semantics the policy adopts when its
load-bearing input (instrument volatility) is unavailable.

The presence of a second implementation also retroactively
{b validates} `Sizing_policy.S` as an abstraction: with only
`Equity_proportional` it was an architectural placeholder
exposed to premature-abstraction critique (YAGNI).
With `Volatility_target` in place, the module type now has two
real consumers whose signature differs along the [volatility]
provider — the abstraction earns its keep on observable
ground, not on the promise of a future.

## Decision

1. **`Volatility_target` formula.** Per-leg quantity is

       qty = book_equity × weight × (target_annual_vol / σ̂) / mark

   where `σ̂` is the instrument's annualised volatility supplied
   by the `volatility` provider. `target_annual_vol` is a
   per-book configuration value (e.g. `0.10` for a 10%
   annualised target). Signed `weight` carries direction; the
   Coupling identifier on `Coupled` intents propagates to every
   output leg.

2. **Refusal sentinel, not fallback.** When the volatility
   provider returns `None` for an instrument (warm-up, missing
   feed) the leg's `target_qty` is **zero**. Same when
   `σ̂ ≤ 0`, `mark ≤ 0`, or `book_equity = 0`. A
   vol-target policy that silently degraded to fixed-fractional
   under missing vol would do exactly the opposite of what an
   operator picking this policy asked for. The sentinel is
   Why3-axiomatised — every refusal branch has its own
   axiom in `volatility_target.mlw`.

3. **Volatility provider implementation.** `Vol_state` —
   a pure-FP rolling-stdev VO in `domain/common/`. Ring buffer
   of log-closes, sample standard deviation with Bessel
   correction, annualised via `sqrt(annualisation_factor)`.
   `current` returns `Some Volatility.t` only after the window
   has filled (warm-up gate). Per-instrument
   `Vol_state ref` lives in `factory.ml`'s registry; `Apply_bar_command_workflow`
   gains a parallel `update_vol` port symmetric to
   `update_mark` so both projections refresh on every parsed
   bar.

4. **Per-book sizing dispatch.** A new domain VO
   `Common.Sizing_policy_choice` holds the discriminator:

       type t =
         | Equity_proportional
         | Volatility_target of { target_annual_vol : Decimal.t }

   `Risk_config` gains a `sizing_policy` field of this type;
   the smart constructor enforces `target_annual_vol ≥ 0`.
   `Factory.sizing_for book_id` resolves the choice at call
   time from the book's `Risk_config` and routes to the
   matching `Sizing_policy.S.size`.

5. **Wire surface.** `Configure_risk_command`'s ATD contract
   extends with a `sizing_policy` variant
   `[ Equity_proportional | Volatility_target of vol_target_config ]`.
   The HTTP route at
   `POST /api/portfolio_management/risk_configs` accepts the
   new shape directly; the existing 8-axis validation
   (book_id, fraction range, decimal parsing, limits,
   construction_source, sizing_policy, target_vol range) flows
   through `Configure_risk_command_handler`'s Rop applicative
   and surfaces as a structured 400 with each violation listed.

6. **Layering.** `Sizing_policy_choice` lives in `domain/common/`
   (not `domain/sizing_policy/`) so the dependency direction
   stays one-way: sizing-policy modules depend on the
   discriminator; the discriminator does not depend on them.
   Variant payloads inline the policy's config rather than
   re-exporting types from `domain/sizing_policy/`.

## Alternatives considered

### A. Vol provider as an admin-defined aggregate (`Volatility_view`)

Make `Volatility_view` a first-class aggregate with its own
`Define_volatility_view_command`, ATD, HTTP route — symmetric
to `Define_pair_mr_command`. Each instrument's vol state would
be explicitly opted in by an operator command.

Rejected because: every bar that updates `mark_for` would also
need to update `update_vol`; the two projections share a
trigger, so requiring a separate admin opt-in to enable vol
tracking creates a footgun (operator forgets to enable vol on
instrument X, vol-target book is silently zero-sized for X).
Auto-tracking per-instrument vol from the bar feed is the
right default — the only operator decision worth gating is
"does *this book* size by vol", and that decision lives in
`Risk_config.sizing_policy`. Auto-tracking has near-zero cost
(O(window) per bar per instrument).

The trade-off is that window/annualisation_factor are global
defaults today (`20` bars, `252` annualisation). A future
per-(book, timeframe) `Volatility_view` aggregate can sub-divide
when intraday/daily mixing becomes operationally relevant; this
ADR does not preclude it.

### B. Fallback to `Equity_proportional` on missing vol

When `σ̂` is unavailable, fall back to `Equity_proportional`'s
formula instead of returning zero.

Rejected because: a book whose operator deliberately chose
`Volatility_target` did so for the vol-aware risk budgeting.
Silent fallback to a different policy contradicts the explicit
choice and creates an invisible regime change at the warm-up
boundary. Worse, in flapping-feed conditions the book would
keep silently switching policies, making P&L attribution
incomprehensible. The zero-sentinel is the loud-failure
discipline equivalent to "if your load-bearing input is
unavailable, do nothing visible". Warm-up is a finite phase
(window = 20 bars); operators can either accept the warm-up
silence or pre-warm the vol state with historical bars before
flipping the book live.

### C. Per-policy `Sizing_policy.S` registry keyed by string tag

Have `Risk_config` carry a `sizing_policy_id : string` and a
registry mapping ids to `Sizing_policy.S` packs. Adding a new
policy = registering the pack; no `Sizing_policy_choice` sum
type needed.

Rejected because: it pushes the discrimination off the type
system (an invalid string id fails at runtime, the sum type
fails at parse). For an Open Source Reference Application
demonstrating formal verifiability, the sum type is the right
encoding: closed, exhaustive, Why3-analysable. The cost (one
edit to the sum type when adding a new policy) is tiny next to
the benefit (the compiler enumerates every dispatch site at
every callsite).

## Consequences

**Easier:**

- A new vol-aware variant (`Inverse_vol`, `Kelly_fraction` with
  payoff variance, `Risk_parity_legs`) plugs in as
  - a new `Sizing_policy.S` module under
    `domain/sizing_policy/`,
  - a new constructor in `Common.Sizing_policy_choice`,
  - a new ATD variant in `configure_risk_command.atd`,
  - a new dispatch branch in `Factory.sizing_for`.

  No upstream pipeline changes; the unified handler is
  policy-agnostic by construction.

- Per-book strategy heterogeneity is explicit and operator-
  controllable: book A can run `Equity_proportional`, book B
  `Volatility_target { 0.10 }`, book C `Volatility_target { 0.20 }`,
  all in the same installation against the same bar feed.

**Harder:**

- A vol-target book is silent during warm-up (window = 20).
  Operators must either tolerate this or seed `Vol_state` with
  historical bars before going live. There is no in-PM
  facility for the latter today; that follow-up belongs in
  ADR-territory of "persistence + replay" rather than this
  ADR's scope.

- The provider's `window` / `annualisation_factor` are global
  defaults. A future operator who wants 30-bar intraday vol on
  one instrument and 60-bar daily vol on another cannot
  express that today — the per-(book, timeframe) `Volatility_view`
  aggregate of Alternative A would be the right resolution.

**To watch for:**

- `Apply_bar_command_workflow` now performs two side-effecting
  projections per bar (`update_mark`, `update_vol`). They are
  ordered but unrelated; should the cost of `update_vol`
  become measurable at scale, both could be batched or moved
  to a dedicated subscription. Today the cost is negligible
  (O(window) per bar).

- The Bessel-corrected sample stdev requires `window ≥ 3`.
  `Vol_state.init` rejects smaller windows; the
  `Configure_risk_command`-side window plumbing does not exist
  yet because window is global. When the per-book vol view
  lands, that smart constructor's validation propagates
  through.

## References

- ADR 0024 — Equity-anchored sizing with explicit Risk_config;
  this ADR materialises its "future Volatility_target / Kelly
  / Inverse_vol" extension point.
- `portfolio_management/lib/domain/common/volatility.{ml,mli,mlw}` —
  non-negative-Decimal VO.
- `portfolio_management/lib/domain/common/vol_state.{ml,mli,mlw}` —
  rolling-stdev estimator.
- `portfolio_management/lib/domain/common/sizing_policy_choice.{ml,mli,mlw}` —
  per-book dispatch discriminator.
- `portfolio_management/lib/domain/sizing_policy/volatility_target.{ml,mli,mlw}` —
  the sizing implementation.
- `portfolio_management/test/component/vol_target_pipeline_test.ml` —
  warm-up refusal and warmed-state sizing BDD scenarios.
