# 0011. Risk evacuation from Strategy; pre_trade_risk and execution_management BCs; Place_order saga

**Status**: Accepted
**Date**: 2026-05-08

## Context

ADR 0009 introduced `portfolio_management` and explicitly deferred
the relocation of `strategy/lib/domain/engine/risk.{ml,mli}` and the
live-engine's portfolio state, noting that the strategy BC was at
that point still importing `account`. ADR 0010 finalised the
strategy → PM contract: `Signal_detected_integration_event` is a
LEAN-style declarative alpha-mind, the only outbound the BC
publishes. Both ADRs left the strategy library structurally
incompatible with the architecture they described:

```
strategy/
└── lib/
    ├── domain/engine/{risk,step,pipeline,backtest}.ml
    │     # Engine.Risk hybrid: cash-buffer / gross-exposure / leverage
    │     # gate (consumed Account.Portfolio.t) + size_from_strength
    │     # construction-time sizing + Engine.Backtest portfolio loop.
    └── application/live_engine/live_engine.ml
          # Eio-backed orchestration: kill-switch (peak/drawdown),
          # rate-limit, reservation lifecycle, broker submission,
          # fill-event reconciliation, pending/placed Hashtbls.
```

Three classes of responsibility were entangled in this code:

1. **Construction-time sizing** — turning `signal.strength` and
   equity into a target quantity. This is policy: how big a position
   the alpha is *allowed* to want. ADR 0009 already hosts the sister
   policy (`Risk_policy.clip`) in PM under `domain/risk/`. The two
   policies operate on the same kind of object (a target proposal)
   with different algebraic shapes — `clip ⊆ identity`,
   `from_strength` constructs from primitives.

2. **Pre-trade hard gate** — refuse a trade intent that would breach
   cash buffer / gross-exposure / leverage caps. This is risk-as-
   gatekeeper, distinct from risk-as-policy: it acts on every order
   regardless of source, and its semantics are *hard veto*, not
   *clip*. ADR 0009 §«Risk-as-policy lives inside PM» named the
   gatekeeper as a separate future BC.

3. **Execution-layer defensive policies** — kill-switch (peak-equity
   / drawdown halt), rate-limit (rolling order count), and the
   coordination of `Reserve(Account) → Submit(Broker) → Release(
   Account)` on rejection. These are applied between an *approved*
   trade intent and venue submission. They are not alpha policy and
   not pre-trade gating — they are the layer LEAN names
   `ExecutionModel` and Nautilus names `ExecutionEngine`.

Beyond the responsibility tangle, the cross-BC import graph was
acyclic only on paper:

```
strategy.engine          → account            (Engine.Risk.check on Account.Portfolio)
strategy.live_engine     → account, broker    (reservation lifecycle, place_order)
strategy.factory         → account, broker    (factory wiring)
```

That violates the project rule that a BC must not import another's
domain code. Microservice extraction of strategy from the present
monolith would be infeasible without these imports being dissolved.

A fourth gap, orthogonal to risk, blocked end-to-end traffic. The
saga that coordinates reserve → submit → release on compensation
had not been built. The shared `workflow_engine` library
(implementing Hohpe & Woolf's Process Manager template, EIP ch. 11)
existed but had no concrete instance. Without it, no cross-BC flow
could connect Strategy's signals to Account's ledger and Broker's
venue, even after the BCs were untangled.

A fifth concern — `strategy/lib/domain/engine/backtest.{ml,mli}`
and the corresponding CLI subcommand and HTTP endpoint — had been
identified as dismantleable: a backtest is not a separate code path
but the same composition with a synthetic broker adapter
substituted. ADR 0009's Pipeline-unification thesis (one
`Pipeline.run` for backtest and live) had already convinced the
codebase that backtest-vs-live equivalence is structural; making it
*also* a composition-level swap removes the last duplicated control
path.

## Decision

Take six structural changes in sequence, each leaving the workspace
green (`dune build`, `dune runtest`, `dune build @fmt`):

### 1. `correlation_id` as first-class field on cross-BC saga DTOs

Introduce `shared/lib/correlation_id/` (a private string newtype
with `make`, `generate : unit -> t` via UUID v4 from `uuidm`).
Thread `correlation_id : string` through eleven cross-BC DTOs that
the `Place_order` saga touches: `Trade_intents_planned_IE`,
`Trade_intent_approved_IE`, `Trade_intent_rejected_IE`,
`Reserve_command`, `Amount_reserved_IE`, `Reservation_rejected_IE`,
`Submit_order_command`, `Order_accepted_IE`, `Order_rejected_IE`,
`Order_unreachable_IE`, `Release_command`. Wire-format DTOs carry
the primitive `string`; only the originating site mints a fresh
identifier — every other DTO echoes the inbound value.

The Process Manager runtime requires this field on every event it
routes (see decision §4). Adding the field as a follow-up after the
saga is in place would mean re-touching every DTO; the prerequisite
checkpoint is the cheaper sequence.

### 2. New BC `pre_trade_risk` (risk-as-gatekeeper)

Mirror Account's per-aggregate domain layout. Aggregate
`Risk_view` keeps cash + per-instrument quantities per `book_id`,
maintained from `Account.Position_changed` and `Cash_changed`
inbound IEs. Aggregate `Risk_limits` is a private record
(`min_cash_buffer ≥ 0`, `max_gross_exposure ≥ 0`,
`max_leverage > 0`, Why3-checkable). Domain service `Assessment`
consumes a `Trade_intent` plus `Risk_view` plus `Risk_limits` and
emits `Approve _ | Reject reason`.

Subscribes to `in-memory://pm.trade-intents-planned`; publishes
`in-memory://pre-trade-risk.trade-intent-{approved,rejected}`. The
old `Engine.Risk.check`, `default_limits`, and `decision` move here
verbatim, with `Account.Portfolio.t` replaced by `Risk_view.t` so
the cross-BC import is dissolved at the same checkpoint.

### 3. New BC `execution_management` (EMS) hosting `Place_order_pm`

Two domain aggregates: `Kill_switch` (peak-equity tracking,
max-drawdown halt) and `Rate_limit` (rolling timestamp window).
Both have Why3-checkable invariants
(`peak_equity ≥ 0`, `halted ⇒ no submissions`).

The saga `Place_order_pm` is a `Workflow_engine.WORKFLOW`
implementation. Its `transition` function is pure
`(state, event) → (state, command list)`. Five live transitions
plus an idempotent fall-through:

| state                          | event                  | next state             | commands                |
|--------------------------------|------------------------|------------------------|-------------------------|
| `Awaiting_reservation`         | `Amount_reserved`      | `Submitted`            | `Submit_order`          |
| `Awaiting_reservation`         | `Reservation_rejected` | `Compensated`          | —                       |
| `Submitted`                    | `Order_accepted`       | `Done`                 | —                       |
| `Submitted`                    | `Order_rejected`       | `Compensated`          | `Release` (compensation)|
| `Submitted`                    | `Order_unreachable`    | `Compensated`          | `Release` (compensation)|
| any                            | duplicate / late event | unchanged              | —                       |

Subscribes to seven inbound topics (Trade_intent_approved_IE
starts a saga instance after kill-switch / rate-limit gating;
Amount_reserved / Reservation_rejected / Order_accepted /
Order_rejected / Order_unreachable advance instances;
Cash_changed feeds Kill_switch). Publishes `Trade_submission_blocked_IE`
on a kill-switch / rate-limit halt and `Kill_switch_tripped_IE`
on a fresh trip.

The kill-switch / rate-limit code that lived inside
`live_engine.ml` is reimplemented as pure aggregates inside this BC.

### 4. Process Manager over Routing Slip

Pick the Process Manager EIP template (Hohpe & Woolf, EIP ch. 11)
for the saga runtime, not Routing Slip (the alternative template;
a reference implementation in OCaml is
[krew-solutions/ascetic-ddd-ml/lib/saga](https://github.com/krew-solutions/ascetic-ddd-ml/tree/main/lib/saga)).

The two templates differ on where saga state lives:

- **Routing Slip**: state is the slip itself
  (`completed_work_logs` + `next_work_items`); each step pops the
  next item and forwards. No external store; no `correlation_id`
  needed because each step receives its full task graph in-band.
  Fits orchestrated synchronous flows where the route is known up
  front.

- **Process Manager**: state lives in a saga-store keyed by
  `correlation_id`; events arrive asynchronously from event buses;
  the engine routes each event to the right instance via a
  `correlation_of_event` projection.

The deciding constraints are: events arrive from two BCs (Account,
Broker) on independent buses, the saga can be paused for arbitrary
time between steps (broker WS may take seconds to minutes to
acknowledge), and the persistence story matters (Postgres-backed
store eventually). Routing Slip cannot serve any of these; PM
serves all three. The cost — `correlation_id` on every inbound DTO
— is paid at decision §1.

### 5. PM `Sizing` domain service

Move `Engine.Risk.size_from_strength` to
`portfolio_management/lib/domain/sizing.{ml,mli,mlw}`, a flat
triple at the domain root (mirrors the
`portfolio_construction.{ml,mli,mlw}` precedent set in ADR 0009 —
both are domain-layer abstractions, not aggregates with sub-state).

Why3 invariants: `0 ≤ strength ≤ 1` enforced by clamp,
`result ≥ 0`, `price = 0 → result = 0` (zero-price sentinel).

PM's `Apply_proposed_targets_on_alpha_direction_changed` handler
extends to call `Sizing.from_strength` before `Risk_policy.clip`
before `Target_portfolio.apply_proposal`. The new
`equity_provider` and `mark_provider` ports are injected from the
factory.

`strategy/lib/domain/engine/risk.{ml,mli}` is deleted at this
checkpoint. The `engine` library no longer imports `account`; the
strategy domain is self-contained.

### 6. PM consumes `Signal_detected_IE`; Strategy collapses to alpha emitter

Add `signal_detected_integration_event_handler` in PM's inbound
ACL: `Signal_detected_IE → Define_alpha_view_command`. PM's factory
subscribes `in-memory://strategy.signal-detected`.

Strategy publishes `Signal_detected_IE` on
`in-memory://strategy.signal-detected`, with a fresh
`Correlation_id.generate ()` per emission.
`live_engine.ml` collapses from ~329 lines to ~50: `on_bar` calls
`Strategy.on_candle`, builds `Signal_detected_IE`, publishes via
the injected port. No more `pending`, `placed`, `peak_equity`,
`halted`, `recent_order_ts`, `mutex`, `submit_order`,
`update_drawdown`, `reconcile`, `on_fill_event`. The struct shrinks
to `{ strategy_ref; publisher; instrument; strategy_id }`.

`strategy/lib/domain/engine/{step,pipeline,backtest}.{ml,mli,mlw}`
and the directory itself are deleted. `strategy/lib/dune`
(`strategy_factory`) drops `account`, `broker`, `engine` from its
`(libraries …)`. **Strategy becomes a pure alpha emitter at this
checkpoint.**

### 7. Backtest via composition, not via a domain `Backtest.run`

Delete `Engine.Backtest`, `Fill_view_model`,
`Backtest_result_view_model`, `backtest_test`. Re-implement the
user-facing surface (`trading backtest <strategy>` CLI, `POST
/api/backtest`) as composition: boot the same in-process trading
host that `serve` boots, with the synthetic broker adapter as data
source and paper-mode order interception, generate N synthetic
candles, drive them through `broker.bar-updated`, tally outbound
integration events into a structured summary.

To enable end-to-end traffic in this composition, add bus
consumers in Account (`account.reserve-command` /
`account.release-command` topics) and Broker
(`broker.submit-order-command` topic). The wire-format DTOs the
saga publishes on these topics are byte-equivalent to the
existing command types, so the consumers parse straight into
`Reserve_command.t` / `Release_command.t` /
`Submit_order_command.t` and route through existing handlers.

### Bounded-context name: `execution_management`, not `execution`

Pick `execution_management` for symmetry with the existing
`portfolio_management`. EMS — Execution Management System — is
the canonical industry term, sister to OMS / PMS / RMS, alongside
the LEAN `ExecutionModel` / Nautilus `ExecutionEngine`
references. `execution` alone is rejected on three grounds: it
has no symmetry with PM; it collides with `core/order.ml`'s
`Order.execution` (the record type for a fill); and it semantically
conflates the *act* of executing (which lives in Broker via the
venue port) with the *policies and gates* that govern that act
(this BC's actual content).

## Alternatives considered

### Keep `Engine.Risk` in strategy

Rejected. Strategy then keeps importing `account`, the BC graph
stays cyclic, microservice extraction stays infeasible, and risk-
as-gatekeeper has no canonical home. ADR 0009 had already named
this as a deferred follow-up; deferring further was not
defensible.

### Combine `pre_trade_risk` and `execution_management` into one BC

Rejected. The two have different invariant classes:
risk-as-gatekeeper is a hard veto (cash buffer, leverage); EMS
defensive policies are throttles and halts (kill-switch,
rate-limit). LEAN and Nautilus split them likewise
(`RiskManagementModel` vs `ExecutionModel`,
`RiskEngine` vs `ExecutionEngine`). One BC hosting both would
also blur the saga shape: the gatekeeper publishes `Approved` /
`Rejected` decisions; the EMS publishes `Submission_blocked`
telemetry and runs the saga. Different command interfaces,
different inbound subscriptions.

### Routing Slip for the saga

Rejected. Account's `Amount_reserved` and Broker's
`Order_accepted` arrive on independent buses; the saga can be
paused arbitrarily between steps; persistence will eventually
matter. Routing Slip's state-in-message model fits orchestrated
synchronous flows, not cross-BC asynchronous compensation. See
decision §4 above for the full comparison.

### Order as a separate aggregate or BC

Rejected. Order lifecycle is saga state in `Place_order_pm`:
identity (`correlation_id`), status transitions
(`Awaiting_reservation` → `Submitted` → `Done | Compensated`),
idempotency on duplicate broker IEs, and cancel-in-flight
invariants are all Process-Manager-state properties.
`broker/lib/application/queries/order_view_model` remains as
the broker-side wire-shape mirror of venue order responses, but
no aggregate is created. The saga is the order-lifecycle owner.

### Delete the user-facing `trading backtest` CLI and `POST /api/backtest`

Rejected. The user-facing surface for historical replay is
valuable and orthogonal to whether replay is a separate code path
internally. The surface is preserved by routing both entry points
through the same `run_backtest_composition` helper that swaps the
synthetic broker in. The internal `Engine.Backtest` is gone; the
external API stays.

### Strategy keeps the live engine for backtest determinism

Rejected. The Pipeline-unification ADR (0004) already established
that backtest and live agree because they share `Pipeline.run`,
not because they share an engine. Once `Pipeline.run` itself is
gone (subsumed by the saga composition), the live engine has no
more reason to host backtest semantics — the composition itself
is the equivalence proof.

## Consequences

**Easier:**

- Strategy is a pure alpha emitter. Its only outbound is
  `Signal_detected_IE`. Its `(libraries …)` no longer mentions
  `account`, `broker`, or `engine`. The BC graph is acyclic in
  practice as well as on paper, and microservice extraction of
  strategy is structurally feasible.
- Each policy class lives where its invariants hold:
  construction-time sizing in PM (sister to `Risk_policy.clip`),
  pre-trade hard gate in `pre_trade_risk` (hard veto), kill-
  switch / rate-limit in `execution_management` (defensive
  throttles), reservation lifecycle in Account (ledger
  invariants), venue submission in Broker (port adapter). No
  responsibility is hosted by a BC whose ubiquitous language
  doesn't match.
- `Place_order_pm` is the canonical Process-Manager instance the
  shared `workflow_engine` library was waiting for. Future sagas
  (cancel-replace, OCO, multi-leg execution) reuse the same
  runtime template.
- `correlation_id` provides a deterministic key for SSE filtering,
  saga store keys (when persistence lands), audit trails, and
  outcome dashboards — surfaces that previously had to invent ad-
  hoc joins from `client_order_id` or `reservation_id`.
- Backtest is the same composition as live, plus a synthetic
  broker swap. There is no second control path to keep in sync;
  the equivalence is structural.

**Harder:**

- Eleven cross-BC DTOs gained `correlation_id`. Wire-format
  changes propagate to every consumer; the field is mandatory
  (non-empty string at the type level), so a producer that omits
  it fails at deserialise time rather than silently. The
  discipline is enforced by the contract.
- Two new BCs to maintain — `pre_trade_risk` (~40 files) and
  `execution_management` (~35 files plus the saga). Each carries
  the standard six-layer dune library set, two test runners, and
  a forward-looking inbound HTTP stub.
- The saga has soft-state today (in-memory `Workflow_engine.
  In_memory_store`). Restart loses in-flight saga instances. A
  Postgres-backed store is the obvious follow-up; the runtime is
  shaped for it (state per `correlation_id`, idempotent
  transitions), but the persistence is not yet wired.

**To watch for:**

- PM's reconcile loop is not driven periodically in the live
  composition. `Signal_detected_IE` reaches PM and updates
  `Target_portfolio`, but `Trade_intents_planned_IE` is emitted
  only when reconcile fires — which happens via
  `Reconcile_command` today. The composition root needs either a
  scheduled `Reconcile_command` dispatch or an event-driven
  trigger (e.g. on `Bar_updated_IE` cadence). The composition
  smoke-tests demonstrate the gap: signals propagate, intents
  do not.
- The saga's `Reserve_command` price is currently filled from
  `Trade_intent_approved_IE.quantity` as a placeholder, because
  the inbound IE lacks a price field. The correct fix is to
  thread mark/last through PM into `Trade_intent_approved_IE`,
  not to widen Account's command. The placeholder is benign as
  long as `quantity > 0`; under that assumption Account's
  `Reserve_command_handler.parse_price` accepts the value and
  the rest of the saga is unaffected.
- `correlation_id` is a routing key, not an idempotency key. Two
  different saga instances may share neither. Receivers that
  want idempotency on duplicates (e.g. Account's `try_reserve`)
  must use their own keys (`reservation_id`); the saga store's
  per-cid uniqueness is not a substitute.
- The kill-switch in EMS subscribes to
  `account.cash-changed`, but Account does not yet publish that
  event. The subscription is structurally complete and inert.
  Until Account's outbound surface grows, the kill-switch
  tracks initial equity only and never trips.

## References

- ADR 0001 — Hexagonal architecture (the layering the BCs follow).
- ADR 0006 — Per-aggregate domain layout (the structure each new
  BC mirrors from Account).
- ADR 0009 — Portfolio Management bounded context (introduced PM,
  named risk-as-gatekeeper as a future BC, deferred the
  evacuation of `Engine.Risk` from strategy).
- ADR 0010 — Alpha-mind vs bracket-exit projection on the
  strategy → PM contract (locked the wire-level semantics that
  let strategy collapse to a pure alpha emitter).
- Hohpe & Woolf, *Enterprise Integration Patterns*, ch. 11 —
  Process Manager template; the basis of `shared/lib/workflow_engine`.
- Hohpe & Woolf, *Enterprise Integration Patterns*, Routing Slip —
  the alternative template; an OCaml implementation lives in
  [krew-solutions/ascetic-ddd-ml/lib/saga](https://github.com/krew-solutions/ascetic-ddd-ml/tree/main/lib/saga).
  Rejected here for the reasons in decision §4.
- LEAN `Algorithm.Framework.{Risk,Execution}` — separate
  `RiskManagementModel` and `ExecutionModel` validating the
  pre-trade vs execution-layer split.
- Nautilus `risk_engine.pyx` and `execution_engine.pyx` — same
  split, different runtime shape.
- Vernon, *Implementing Domain-Driven Design*, ch. 14 (Application
  Layer) — Process-Manager-as-application-service.
- Wlaschin, *Domain Modeling Made Functional*, ch. 9 — the
  Railway-Oriented saga with explicit compensation, the conceptual
  shape `Place_order_pm.transition` realises.
