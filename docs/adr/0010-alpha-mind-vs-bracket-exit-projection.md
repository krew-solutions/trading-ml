# 0010. Alpha-mind vs bracket-exit projection on the strategy → PM contract

**Status**: Accepted
**Date**: 2026-05-05

## Context

`strategy` publishes `Signal_detected_integration_event` to announce
that a strategy detected an actionable signal on a bar close. The
domain type carrying this decision is `Common.Signal.t`, with an
action enum:

```ocaml
type action = Enter_long | Enter_short | Exit_long | Exit_short | Hold
```

The integration event reduces this five-way action into a coarser
wire-format `direction : string` field — `"UP" | "DOWN" | "FLAT"` —
because:

- Across the BC boundary `direction` is the only category Portfolio
  Management's alpha-driven construction policy needs (sign for
  signed target sizing).
- Strategies don't *authoritatively* know their actual position;
  they don't get to assume that a closing intent rolls into an
  opposite directional view.

The original projection (introduced at the same time as the IE) was:

```
Enter_long  | Exit_short -> "UP"
Enter_short | Exit_long  -> "DOWN"
Hold                     -> "FLAT"
```

The justification was symmetric: *a bullish bar produces direction
= "UP" regardless of whether the strategy thinks of it as opening a
long or closing a short*. That argument holds **only if** strategies
emit `Exit_*` purely to express «the bar is bearish, so my prior
short closes». It breaks for strategies that emit `Exit_*` to
express «my own position-management barrier fired and the alpha is
withdrawn».

The breaking case is concrete and lives in the codebase today:
`strategies/bracket.ml` is a decorator that wraps an inner strategy
with TP / SL / timeout barriers (the runtime mirror of the
*triple-barrier* labelling method from López de Prado's *Advances
in Financial Machine Learning*, implemented at
`ml/triple_barrier/triple_barrier.ml`). When `bracket` fires
`Exit_long`, it does **not** mean «the bar is now bearish». It
means: *my UP-view closed, outcome = SL hit / TP hit / timeout, and
my internal `position` transitions to `Flat`*. Routing this through
`Exit_long → "DOWN"` would publish an IE that says «open a short»
for a strategy whose internal state is now flat — alpha-policy in
PM would size a SHORT target equal to the long the bracket just
unwound, **doubling exposure** instead of letting reconcile bring
it back to zero.

This is exactly the failure mode that brackets exist to prevent,
realised one layer up at the integration-event boundary.

The phrase «strategy doesn't know its position» in the original
mli was true for strategies whose action set is `Enter_* | Hold`,
but `bracket` is a counter-example: it owns a *synthetic* position
(its own state machine, not the broker's), and it fires `Exit_*`
based on that synthetic position. Bracket cannot be removed from
the strategy BC: the runtime barriers must agree with
`Triple_barrier.label`, which generates training labels for ML
classifiers — diverging the runtime exit logic from the labeller
introduces train/serve mismatch and silently invalidates trained
models. Brackets are part of the alpha specification, not
reusable position management.

The canonical reference systems split this differently. **LEAN**'s
`InsightDirection` carries only `Up | Flat | Down`. There is no
«exit» direction; alpha withdrawal is realised through Insight
*expiry*, which `PortfolioConstructionModel` translates into a
`PortfolioTarget(symbol, 0)` — a flatten target. Cancellation of
in-flight orders is the `ExecutionModel`'s job, downstream of the
target update. **Nautilus** takes the opposite tack: strategies
hold a direct reference to `Position`, call
`strategy.close_position(position, reduce_only=True)` imperatively,
and the *concept* of an «exit signal» does not exist as a
contract type. Both architectures avoid encoding `Exit_*` as a
directional opinion.

Our architecture is closer to LEAN's: separate BCs, integration
events as the only cross-BC channel, no shared in-process Position
references. The implication is that the LEAN convention applies —
`direction` is alpha-mind only; «exit» is alpha-expiry mapped to
`FLAT`.

## Decision

`Signal_detected_integration_event.direction` is a **declarative
alpha-mind**: `"UP"` and `"DOWN"` state the strategy's current
directional opinion; `"FLAT"` states the absence of one (whether
because the strategy currently holds no view — `Hold` — or because
its prior view has been withdrawn — `Exit_long` / `Exit_short`).

The projection is therefore:

```
Enter_long              -> "UP"
Enter_short             -> "DOWN"
Exit_long | Exit_short  -> "FLAT"   (alpha-expiry)
Hold                    -> "FLAT"
```

The asymmetry between `FLAT-from-Hold` and `FLAT-from-Exit_*` —
the latter carries an outcome label («SL hit», «TP hit»,
«timeout» from `Bracket`) — is preserved verbatim in the existing
`reason : string` field. `reason` is **telemetry only**: it lets
downstream consumers (ML drift monitors, win-rate dashboards,
audit) distinguish the cases for analytics. Consumers MUST NOT
switch on `reason` to make trading decisions; that conflates the
analytic and operational channels and re-introduces the
category error this ADR exists to remove.

Bracket stays in `strategy/lib/domain/strategies/`. Its role as
the runtime mirror of `Triple_barrier.label` makes it part of
alpha specification, not position management.

## Alternatives considered

**Keep the original mapping** (`Exit_short → "UP"`,
`Exit_long → "DOWN"`). Rejected: the `bracket` case demonstrates
that this mapping is unsound for any strategy that emits `Exit_*`
based on its own synthetic position rather than as a proxy for
bearish/bullish bar direction. The bug surfaces silently: PM
doubles exposure on every bracket exit.

**Map `Exit_long → "DOWN"` only when the underlying bar was
bearish, etc.** — i.e., reuse the entry/exit asymmetry on the
outbound side conditionally on bar context. Rejected: the
strategy is the wrong place to make the «is this exit also a
directional reversal?» judgement. The strategy emits `Exit_*` to
express *its own state transition*; the bar context that triggered
the transition is incidental. Conflating the two on the wire
re-creates the same category error this ADR removes, with extra
conditional branches.

**Remove `Exit_long` / `Exit_short` from `Signal.action` entirely.**
Considered, deferred. `Exit_*` is consumed inside strategy BC by
`engine/step.ml` (sizing), `composite.ml` (state transitions), and
`features.ml` (ML features). Reshaping `Signal.action` into a
tagged union of «alpha-mind» (Enter_*/Hold) vs «alpha-expiry»
(Exit_* with outcome) is a larger refactor; it would also clarify
`composite.ml`'s `is_exit` helper and the `features.ml` collapse
of `Exit_* | Enter_short → -1.0`. Worth doing, but a separate
change. The wire-level fix in this ADR is independent of and
compatible with that future refactor.

**Add a `period` / `expires_at` field to `Signal.t` (LEAN-style
declarative expiry).** Considered, deferred. Today expiry is
implicit: the strategy emits `Exit_*` on the bar where its
barrier resolves. To make alpha withdrawal scheduler-driven
(independent of the next bar arriving), the field is needed and
PM gains a timer-driven expiry mechanism. Defer until a concrete
consumer requires it.

**Migrate `Bracket` out of strategy BC into a Risk or Position
Manager BC.** Reverted during this discussion. Bracket is the
runtime image of `Triple_barrier.label`, and offline label
generation must agree with online barrier behaviour to keep
trained classifiers valid. Bracket is alpha specification, not
generic position management.

## Consequences

**Easier:**

- Bracket exits no longer silently double exposure when consumed
  by PM's alpha-policy. The chain `bracket exit → Direction_changed
  (X → Flat) → target_qty = 0 → reconcile → close trade` becomes
  the canonical path.
- The contract is now consistent with LEAN's `InsightDirection`,
  reducing surprise for readers familiar with that reference.
- `reason` carries the outcome label cleanly; analytics get a
  precise signal of *why* the alpha closed without polluting the
  trading-decision channel.

**Harder:**

- `direction = "FLAT"` is now polysemous on the wire (alpha
  inactive vs alpha withdrawn). Audit / replay tooling that wants
  to distinguish the two cases must consult `reason` — and the
  contract explicitly prohibits trading logic from depending on
  that distinction. The discipline is enforced by code review and
  by the docstring on the `direction` field.
- `Exit_long`/`Exit_short`/`Hold` all collapse to the same wire
  value. If an external consumer ever needs to act on the
  entry-vs-exit distinction (e.g. a future Execution BC choosing
  reduce-only orders when the prior intent was an entry), it
  reads that distinction from PM's outbound `Trade_intent` —
  which knows the actual delta against the held position — not
  from `Signal_detected_IE`. This ADR consciously routes that
  information through the right contract.

**To watch for:**

- When a `Signal_detected_integration_event_handler` is added in
  PM (currently absent), it must translate `direction = "FLAT"`
  into `Define_alpha_view_command` with `direction = "FLAT"`.
  Through `Alpha_view.define` this produces `Direction_changed
  (X → Flat)`, which fans out via
  `Apply_proposed_targets_on_alpha_direction_changed` and yields
  `target_qty = 0`. Whether to propagate `reason` into the
  command DTO for telemetry is a PM decision, not strategy's.
- Closing a position when target moves to zero is **not** a separate
  cross-BC concern — it is already realised by the existing chain:
  PM owns both `Target_portfolio` (intended state) and
  `Actual_portfolio` (observed state); `direction = FLAT` zeroes the
  target, the next reconcile diff produces a closing
  `Trade_intent`, the outbound `Trade_intents_planned_IE` carries
  it. No separate «position-management imperative» channel is
  needed; introducing one would re-create the same category-mixing
  this ADR removes.
- The narrower concern that **does** sit outside PM is order
  lifecycle management: when a new `Trade_intents_planned_IE`
  arrives while a prior order from the previous intent is still
  in-flight, somebody must decide whether to cancel it, let it
  fill, or coexist with the new order. That decision is execution-
  layer work — it requires knowledge of which orders this engine
  has placed, which are still working, and venue-specific cancel
  semantics. Today the codebase has no Execution BC; `broker` is a
  venue gateway, not an execution engine. The gap is acknowledged
  but not closed by this ADR. It does not affect the strategy → PM
  contract — when the gap is filled, the consumer of
  `Trade_intents_planned_IE` is the new piece, not a parallel
  exit-signal channel.

## References

- `strategy/lib/application/integration_events/signal_detected_integration_event.{ml,mli}`
  — projection and contract.
- `strategy/lib/domain/strategies/bracket.ml:94, 118` — only
  emitters of `Exit_long` / `Exit_short` constructed as actual
  `Signal.t` values.
- `strategy/lib/domain/ml/triple_barrier/triple_barrier.ml` —
  offline labeller whose semantics `bracket.ml` mirrors at
  runtime; the train/serve consistency that pins `bracket` to the
  strategy BC.
- [docs/architecture/ml/triple_barrier.md](../architecture/ml/triple_barrier.md)
  — full rationale for triple-barrier labelling and the
  bracket/labeller train-serve alignment that this ADR depends on.
- [docs/architecture/ml/gbt.md](../architecture/ml/gbt.md) —
  consumer of triple-barrier labels; the ML strategy whose
  classifier validity would be silently broken if `bracket`
  semantics diverged from `Triple_barrier.label`.
- `strategy/test/unit/application/integration_events/signal_detected_integration_event_test.ml`
  — locks in the five-way mapping.
- LEAN `InsightDirection` (Common/Algorithm/Framework/Alphas/InsightDirection.cs)
  and `PortfolioConstructionModel.cs` — declarative expiry → flatten target.
- Nautilus `trading/strategy.pyx::close_position` — imperative
  alternative; rejected for our cross-BC architecture.
- ADR 0009 — Portfolio Management bounded context (consumer of
  the corrected contract).
