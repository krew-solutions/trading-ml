# 0027. Adaptive-β pair mean reversion as a sibling policy

**Status**: Accepted
**Date**: 2026-05-24

## Context

The `portfolio_management` BC has shipped a static-β pair
mean-reversion policy (`Pair_mean_reversion`) since the
construction → sizing → clipping pipeline went in. The
`hedge_ratio` is supplied as a `Common.Hedge_ratio.t` at
`Define_pair_mr_command` time and frozen for the policy's
lifetime.

Static β is a well-documented failure mode of statistical
arbitrage (Pole, *Statistical Arbitrage*; Chan, *Algorithmic
Trading*, гл. 3; Bramante-Cordasco-Faraoni, *Statistical
Arbitrage and Pairs Trading*). β between two cointegrated assets
drifts on horizons longer than a few weeks; a fixed value yields a
systematically biased spread z-score, so positions open against a
non-zero true equilibrium and the mean-reversion edge converges to
zero or worse.

The canonical fix is a **Kalman filter** treating (α, β) as a
slowly-varying hidden state under a linear-Gaussian DLM. The
filter consumes paired log-close observations and produces an
adaptive β each bar; the spread z-score becomes the filter's own
innovation z-score, which is by construction centered at zero
under correct specification.

This ADR records the choices taken in materialising the adaptive
variant alongside (not replacing) the static one. The two
coexist so the static implementation continues to serve as the
A/B baseline for any future evaluation work.

## Decision

### 1. Sibling implementation under `Portfolio_construction.S`

The adaptive policy is a **separate subdir**
`portfolio_management/lib/domain/pair_kalman_mean_reversion/`,
implementing `Portfolio_construction.S` independently. It is
**not** a config-variant of the existing static policy.

Rationale: the two algorithms share an outer skeleton
(hysteresis state machine, leg caching, Coupled-intent shape)
but diverge in everything that matters internally:

- **State**: a rolling spread ring vs. a Kalman posterior with
  symmetric 2×2 covariance plus Welford innovation statistics.
- **z-score**: rolling standardised residual vs. Bayesian
  innovation z with empirical-scale floor.
- **Config**: `(window, hedge_ratio, …)` vs.
  `(discount, v, prior_*, burn_in, …)` — non-overlapping knobs.
- **Failure modes**: ring-not-full vs. PSD violation; rolling
  variance collapse vs. mis-specified observation noise.
- **Why3 invariants**: structural ring properties vs. Joseph-form
  PSD preservation.

A `Hedge_ratio_policy = Static | Adaptive` variant would
pollute the smart-constructor invariant surface and force
case-split in every `.mlw` lemma; two opaque siblings sharing the
small set of genuinely common pieces (`Pair_direction` VO,
`Pair_intent_builder`) keep each algorithm self-contained at the
cost of ~30 lines of duplicated hysteresis logic. The cost is
worth it.

### 2. Shared VO extraction (`Pair_direction`, `Pair_intent_builder`)

Two pieces are genuinely identical across the two policies and
live in `domain/common/`:

- `Pair_direction.t = Flat | Long_spread | Short_spread` — the
  hysteresis state space, formerly nested as
  `Pair_mr_state.Direction`. The static policy re-exports it
  through a module alias for backward compatibility of existing
  call-sites; new code reaches it directly under
  `Common.Pair_direction`.
- `Pair_intent_builder.build` — the function mapping
  `(direction, β, pair, book_id, source, observed_at,
  coupling_source)` to a `Construction_intent.Coupled`. β is
  passed as `float` (not `Hedge_ratio.t`) because the Kalman
  posterior mean has no positive-definiteness guarantee at the
  bar where the policy fires; the builder clamps `β < 1e-6` to
  `1e-6` before converting to `Decimal`, absorbing transient
  near-zero values without raising.

### 3. Harrison-West canonical discount, not additive process noise

Process noise is parameterised by a single **discount factor**
`δ ∈ (0, 1)` per Harrison & West, *Bayesian Forecasting and
Dynamic Models* (2nd ed., 1997), §6.3:

    C_pred = C_prev / δ

This is the **multiplicative** form — process noise scales with
current uncertainty, so a near-converged filter advances slowly
while an under-warmed-up filter still moves. The QuantStart
walk-through (referenced in early scoping discussion) uses an
**additive** form
`C_pred = C_prev + (δ/(1-δ))·I`
which is a fixed isotropic noise injection unrelated to current
covariance. The canonical form is more principled and we adopt
it.

Trade-off: numerical stability requires δ strictly bounded away
from zero. The smart constructor enforces `0 < δ < 1`; the
intended operating range is approximately `0.99 … 0.9999`
(daily-bar β changes very slowly).

### 4. Joseph form for posterior covariance

The posterior covariance update uses the Joseph form

    C_post = (I − KH) C_pred (I − KH)ᵀ + K v Kᵀ

rather than the naive `C_post = (I − KH) C_pred`. The Joseph
form preserves positive semi-definiteness across long horizons
under 64-bit floating-point arithmetic by construction
(asymmetry cannot accumulate). The naive form silently drifts
asymmetric and breaks downstream guarantees. Cheap insurance:
~10 extra multiplications per bar.

This is **not** verified in Why3 — PSD preservation by a
specific floating-point update sequence is a numerical-analysis
property, not a domain invariant. It is covered by a stress
test (`kalman_dlm_state_test`: 1000 synthetic bars; assert PSD
within `1e-12` tolerance on every snapshot).

### 5. Empirical-scale floor on the innovation z-score

The innovation z-score is

    z = e / sqrt(max(Q_filter, S_empirical))

where `Q_filter = H C_pred Hᵀ + v` is the filter's predictive
variance and `S_empirical` is a Welford-estimated running
variance over past innovations. The `max(…)` is the load-bearing
defence: if the operator's `v` under-states the true observation
noise, `Q_filter` collapses and the naive `e/√Q_filter` would
blow z up by orders of magnitude — silently miscalibrating the
hysteresis thresholds. The empirical floor catches that within
roughly 20 paired bars.

A more principled alternative would be a **variance-discount
filter** (Harrison & West §10) that puts `v` into the state and
discounts it like the location parameters. We deferred that to
v2; the empirical floor covers the failure mode at a fraction
of the implementation cost.

### 6. Operator-configurable priors

`prior_alpha`, `prior_beta`, `prior_variance` are exposed as
operator knobs in the wire contract rather than hardcoded
defaults. Priors are load-bearing for any Bayesian filter and
pair-specific economic judgements (β ≈ 1 for two oil majors
vs. β ≈ 0.3 for a stock against its sector basket cannot be a
fixed default).

`prior_beta` must be strictly positive — mirrors the
`Hedge_ratio.t` invariant. `prior_variance` must be strictly
positive — applied diagonally to both state components in
`C_0`. `prior_alpha` is unconstrained.

### 7. Explicit `~pair_kalman_mr_states_for`, no policy registry

`Apply_bar_command_handler.handle` and
`Apply_bar_command_workflow.execute` gain a single new labelled
argument `~pair_kalman_mr_states_for` parallel to the existing
`~pair_mr_states_for`. Both iterators run on every bar and
accumulate intents into the same downstream list.

We considered a generalised `policy_registry` abstraction (a
closed sum over policy state types or an existential wrapper).
We rejected it: only two implementations exist, and CLAUDE.md's
"no premature abstraction" rule applies (cf. ADR 0006). A third
construction policy that doesn't reduce to scalar-or-pair shape
would justify the refactor; today's variations don't.

### 8. New `Source.t` variant + `configure_risk` extension

`Common.Source.t` gains a third variant
`Pair_kalman_mean_reversion of Pair.t`. The wire contract
`configure_risk_command.atd` is extended in parallel so an
operator can authorise a Kalman-driven book via the same REST
endpoint they already use; `configure_risk_command_handler`
parses the third arm. `Risk_config.authorises` is unchanged —
it relies on structural `Source.equal`, which now distinguishes
the two pair variants structurally.

The ATD extension is **load-bearing**: without it the variant
would be unauthorisable, the unified handler would silently
drop every Kalman intent via `Risk_config.authorises`, and the
policy would ship green but trade nothing. This was flagged
during planning and explicitly addressed.

### 9. New HTTP route, new command, no new bus subscription

`POST /api/portfolio_management/pair_kalman_mr_policies` defines
the operator-facing entry; the route parses
`Define_pair_kalman_mr_command`, calls the handler, returns the
Rop result over JSON. The factory's existing
`in-memory://broker.bar-updated` subscription
(group `portfolio-management-pair-mr`) drives both policy
families through `dispatch_apply_bar`; **no second subscription**
— a parallel subscription would double-process every bar.

## Consequences

- Adaptive-β pair MR is wireable today without disturbing the
  static-β policy. Both can run concurrently on different books
  (one source per book via `Risk_config.authorises`).
- The `Sizing_policy.S` and `Risk_policy.clip` pipeline is
  reused unchanged: the policy emits the same `Coupled` shape,
  with the same `Coupling.t` semantics for β-ratio preservation
  under clipping.
- Why3 coverage on the new policy is structural-only (hysteresis
  axioms, init-is-flat lemma). Joseph-form PSD preservation,
  β-convergence, and discount-factor effects on posterior
  variance are out of Why3 scope and covered by tests
  (`kalman_dlm_state_test` includes a 1000-bar PSD stress
  loop and a β-convergence sanity check on synthetic data).
- A naming asymmetry persists: the static policy's events live
  under `pair_mean_reversion/events/target_proposed.*`, the
  adaptive policy's under
  `pair_kalman_mean_reversion/events/target_proposed.*`. The
  two `Target_proposed` types are structurally identical but
  nominally distinct so audit logs name the originating
  policy without parsing a tagged source string. This is
  intentional.

## Out of v1 scope

- **Variance-discount filter** (Harrison & West §10) that
  estimates `v` online. The empirical-scale floor covers the
  most common mis-specification at much lower cost; we revisit
  when operators report calibration friction.
- **Kalman state persistence** across restarts. Same posture as
  every other PM aggregate today — uniform in-memory state.
- **Multi-pair coupling** (β covariance across pairs). The
  current model is per-pair; a basket-Kalman construction would
  be a separate `Portfolio_construction.S` implementation.
- **Innovation-based half-life estimate** (OU-style mean
  reversion validation). A useful sanity check for whether a
  given pair is suitable for the policy at all, but it lives
  outside the policy and outside this ADR.

## References

- Harrison, P. J. & West, M. *Bayesian Forecasting and Dynamic
  Models*, 2nd ed., Springer, 1997, §6.3 (discount factors),
  §10 (variance discount).
- Chan, E. P. *Algorithmic Trading: Winning Strategies and
  Their Rationale*, Wiley, 2013, гл. 3.
- Pole, A. *Statistical Arbitrage: Algorithmic Trading Insights
  and Techniques*, Wiley, 2007.
- Bramante, R., Cordasco, M. & Faraoni, V. *Statistical
  Arbitrage and Pairs Trading: Cointegration Approach and
  Practical Trading Issues*, 2019.
- ADR 0006: Aggregate layout under `domain/`.
- ADR 0024: Equity-anchored sizing and `Risk_config`
  separation of concerns.
- ADR 0026: Bar-stream multi-timeframe routing.
