# Bounded contexts — top-level architecture

This page describes the system as a graph of bounded contexts (BCs)
and the integration events that flow between them. The view is the
one a reviewer reaching for the codebase for the first time should
hold in mind: which BC owns which decision, where the boundaries
sit, and how the place-order saga threads through them.

The conceptual layering inside each BC (Hexagonal — domain /
application / infrastructure) is documented separately in
[`hexagonal-architecture.md`](hexagonal-architecture.md). This page
sits one level above and is concerned only with the graph.

## The map

```
                                ┌──────────────────────────┐
                                │  Strategy                │
                                │  (alpha emitter)         │
                                └────────────┬─────────────┘
                                             │
                                             │ Signal_detected_IE
                                             ▼
                                ┌──────────────────────────┐
            Bar_updated_IE      │  Portfolio Management    │
        ┌──────────────────────►│  (target portfolio,      │
        │                       │   sizing, clip, reconcile│
        │                       └────────────┬─────────────┘
        │                                    │
        │                                    │ Trade_intents_planned_IE
        │                                    ▼
        │                       ┌──────────────────────────┐
        │                       │  Pre-trade Risk          │
        │                       │  (cash buffer, gross,    │
        │                       │   leverage hard gate)    │
        │                       └────────────┬─────────────┘
        │                                    │
        │                                    │ Trade_intent_approved_IE
        │                                    ▼
        │                       ┌──────────────────────────┐
        │                       │  Execution Management    │
        │                       │  (kill-switch,           │
        │                       │   rate-limit,            │
        │                       │   Order_process_manager saga)│
        │                       └─┬───────────────────┬────┘
        │                         │                   │
        │            Reserve_cmd  │                   │  Submit_order_cmd
        │                         ▼                   ▼
        │       ┌──────────────────┐         ┌────────────────────┐
        │       │  Account         │         │  Broker            │
        │       │  (cash, holdings,│         │  (brokerage data   │
        │       │   reservations,  │         │   source:          │
        │       │   margin)        │         │   Finam / BCS /    │
        │       └────────┬─────────┘         │   Synthetic)       │
        │                │                   └────────┬───────────┘
        │                │  Reservation_filled_IE     │
        └────────────────┘                            │  Bar_updated_IE
                                       ▲              │
                                       │              ▼
                              Order_filled_IE  ┌────────────────────┐
                                       │      │  paper_broker      │
                                       └──────┤  (in-memory order  │
                                              │   matching against │
                                              │   the bar stream;  │
                                              │   optional, paper  │
                                              │   deployments only)│
                                              └────────────────────┘
```

The eight boxes are the bounded contexts of the system. The
ninth piece — the **trading host** — is the composition root in
`bin/main.ml` and `lib/infrastructure/inbound/http`; it builds a
`Bus.t`, registers the in-memory broker, instantiates each BC's
factory, and exposes one HTTP server that delegates to per-BC route
handlers via `Inbound_http.Route.handler`. The host is not a BC; it
holds no domain model and publishes no integration events of its
own.

`paper_broker` is the only optional BC: it is instantiated only
when the trading host is started with `--paper` (or for the
backtest path). The other seven are always present. ADR 0012
covers paper_broker's role and why it is a separate BC instead of
a Paper decorator inside broker.

The seven **canonical pipeline stages** (Alpha → Construction →
Risk → Execution) of LEAN's Algorithm Framework correspond to four
of the BCs:

| Stage                     | Bounded context         | LEAN equivalent                |
|---------------------------|-------------------------|--------------------------------|
| Alpha                     | strategy                | `AlphaModel`                   |
| Portfolio construction    | portfolio_management    | `PortfolioConstructionModel`   |
| Pre-trade risk            | pre_trade_risk          | `RiskManagementModel`          |
| Execution                 | execution_management    | `ExecutionModel`               |

Account and Broker are not in LEAN's framework because LEAN models
the trading host as a single in-process algorithm; the equivalent
roles are split across `IBrokerage` (the brokerage abstraction
that routes orders to the venue and surfaces fills) and the
algorithm's portfolio bookkeeping. In our system Account owns the
ledger as a separate BC because its invariants (`cash ≥ 0`,
reservations ≤ buying power, margin model) are accounting
invariants that deserve their own model and Why3 surface — see
ADR 0009 §«Merge target portfolio into the existing account BC» on
why this split is load-bearing rather than incidental.

## The seven BCs

### `strategy` — alpha emitter

Single-instrument decision policies (`Strategy.S`). Eleven concrete
implementations from `sma_crossover` to `bracket(gbt)`. Indicators
(SMA, EMA, RSI, MACD, Bollinger, MFI, OBV, ADL, Chaikin, Stochastic
and friends) compose into strategies. Signals carry a coarse
`direction = "UP" | "DOWN" | "FLAT"` projection of the strategy's
five-way `Signal.action`; ADR 0010 pins the projection.

**Inbound** ← `broker.bar-updated` (one bar per close per
instrument per timeframe).
**Outbound** → `strategy.signal-detected` (one IE per non-Hold
signal, fresh `correlation_id` per emission).

The BC has no reference to Account, Broker, PM, or the saga. Its
`(libraries …)` graph reads as `core common decimal datetime
strategies indicators stream eio_stream strategy_inbound_*
strategy_integration_events strategy_domain_event_handlers
correlation_id inbound_http`. ADR 0011 collapsed
`live_engine.ml` from ~329 lines to ~50 to make this true.

### `portfolio_management` — target portfolio, sizing, reconcile

ADR 0009. Two first-class portfolio aggregates:
`Target_portfolio` (intended state) and `Actual_portfolio`
(observed state from inbound Account events). Construction-time
policies live in `domain/`: `Sizing.from_strength` (signal strength
+ equity → target_qty, ADR 0011), `Risk_policy.clip` (per-instrument
cap, gross-exposure cap with hedge-symmetric scaling).
`Portfolio_construction.S` is the abstraction with one current
implementation (`pair_mean_reversion`); the alpha-mind path used
today is `define_alpha_view → apply_proposed_targets_on_alpha_direction_changed`.
`Reconciliation.diff` produces trade intents from the
target-vs-actual delta.

**Inbound** ← `strategy.signal-detected` (alpha mind);
`account.reservation-filled` (atomic fill fact — new cash
+ position + avg_price in one payload, preserving the equity
invariant); composition-driven `Reconcile_command` (today via
test or HTTP, periodic dispatch is a known follow-up).
**Outbound** → `pm.target-portfolio-updated` (target-set
notification); `pm.trade-intents-planned` (per-leg trade
intents with `correlation_id` per leg).

### `pre_trade_risk` — risk-as-gatekeeper

ADR 0011. Aggregate `Risk_view` keeps cash + per-instrument
quantities per `book_id`, maintained from inbound Account IEs.
Aggregate `Risk_limits` is a private record with Why3-checked
positivity invariants. `Assessment.assess` consumes a trade intent
plus `Risk_view` plus `Risk_limits` and emits
`Approve _ | Reject reason`.

**Inbound** ← `pm.trade-intents-planned`;
`account.reservation-filled`.
**Outbound** → `pre-trade-risk.trade-intent-approved` |
`pre-trade-risk.trade-intent-rejected` (each carries the per-leg
`correlation_id` echoed from the input).

The hard veto here (cash buffer / gross / leverage) is distinct
from PM's soft clip in `Risk_policy`. Both can speak the same
vocabulary (`max_drawdown` etc.) and that is fine: they apply at
different points of the pipeline with different semantics.

### `execution_management` — defensive policies and the place-order saga

ADR 0011. Two domain aggregates: `Kill_switch` (peak-equity
tracking, max-drawdown halt) and `Rate_limit` (rolling timestamp
window). Both Why3-checkable. The BC also hosts the
`Order_process_manager` Process Manager — the saga that sequences
`Reserve(Account) → Submit(Broker) → Release(Account)` on
compensation. The saga runtime is `shared/lib/workflow_engine`
(the Process Manager template per Hohpe & Woolf, EIP ch. 11);
saga state is kept in an `In_memory_store` keyed by
`correlation_id` (Postgres-backed store is the obvious
follow-up).

The five live state transitions plus the idempotent fall-through
are covered by ADR 0011 §3.

**Inbound** ← `pre-trade-risk.trade-intent-approved` (saga
starter; runs the kill-switch / rate-limit gate then
`Engine.start`); `account.amount-reserved`,
`account.reservation-rejected`,
`broker.order-{accepted,rejected,unreachable}` (saga
transitions); `account.reservation-filled` (kill-switch
peak/drawdown update — uses the IE's `new_cash` field as an
equity proxy until a mark-to-market feed lands).
**Outbound** → `account.reserve-command`, `account.release-command`,
`broker.submit-order-command` (saga-driven commands published as
wire JSON; Account / Broker subscribe and deserialise straight
into their existing command types);
`pre-trade-risk.trade-submission-blocked` (telemetry on a
gate halt); `pre-trade-risk.kill-switch-tripped`.

The naming choice `execution_management` over `execution` is
covered in ADR 0011's BC-name section (symmetry with PM, EMS as
the canonical industry term, and `execution` collides with
`Order.execution`).

### `account` — ledger of holdings and reservations

ADR 0005, ADR 0008. Authoritative on cash, positions, and
reservations. `Portfolio` aggregate with `try_reserve` / `commit_fill`
/ `release` semantics; the Buy path is cash-bounded, the Sell-open
path is collateral-bounded via `Margin_policy`.

**Inbound** ← `account.reserve-command`, `account.release-command`
(saga-driven, ADR 0011 §7);
`broker.order-rejected`, `broker.order-unreachable` (idempotent
compensation when the saga didn't run, e.g. legacy paths);
direct `dispatch_reserve` from `POST /api/orders` (still in
place for manual order placement smoke-tests).
**Outbound** → `account.amount-reserved`,
`account.reservation-released`, `account.reservation-rejected`,
`account.reservation-filled` (atomic fill fact — carries
`new_cash`, `new_position_quantity`, `new_avg_price` together so
downstream readers in PM, `pre_trade_risk`, and EMS never
observe a transient state that violates
`equity = cash + Σ qty × mark`).

### `broker` — brokerage abstraction

The single port `Broker.S` (covered in ADR 0001 §«The core
abstraction») abstracts the brokerage — the firm or service that
routes our orders to a venue and surfaces market data and fills
back. The `venues : t -> Mic.t list` method on the port reflects
the asymmetry: a brokerage covers one or more venues; the BC is
*not* a venue itself. Adapters: Finam REST + WS, BCS
REST + WS, Synthetic (deterministic random walk for demos and
backtest). The WS bridges fan inbound bars into
`broker.bar-updated`; bars and fills run through a per-stream
[transport supervisor](transport-supervisor.md) so a WS
disconnect transparently engages REST polling and reconnect
runs a synchronous catch-up. Order matching against the bar
stream is not this BC's responsibility; see `paper_broker`
below for the simulated-execution side.

**Inbound** ← `broker.submit-order-command` (saga-driven,
ADR 0011 §7) — gated off in paper deployments where the
paper_broker BC owns this channel;
direct REST/HTTP for manual orders.
**Outbound** → `broker.order-accepted`, `broker.order-rejected`,
`broker.order-unreachable` (the three terminal saga events, with
`correlation_id` echoed); `broker.bar-updated` (the upstream
candle stream that drives Strategy, PM, and paper_broker
downstream).

### `paper_broker` — simulated execution

Optional BC instantiated when the host runs with `--paper` (or
for the backtest path). Subscribes to `broker.submit-order-command`
(saga channel, wire-byte-equivalent to broker's local
`Submit_order_command`) and `broker.bar-updated` (mirrored via
this BC's own inbound ACL), persists working orders and emits
fills against the bar stream using a pure-FP matching engine
(`Matching.price_if_filled` + `Slippage.apply` + `Fee.compute`).
The Domain layer has Why3 specs for the entity (`Order`), the
matching rules, and the VOs. Persistence shape — pure
`Repository<Order>` + a separate process-correlation log — is
covered by *Process correlation is not aggregate state* in
[hexagonal-architecture.md](hexagonal-architecture.md).

**Inbound** ← `broker.submit-order-command`,
`broker.cancel-order-command` (saga-driven command channels;
shapes are byte-equivalent to local DTOs, no handler file needed),
`broker.bar-updated` (ACL'd into `Apply_bar_command`).
**Outbound** → `broker.order-accepted`, `broker.order-rejected`,
`broker.order-filled`, `broker.order-cancelled` (every event
carries the original `correlation_id` and the round-trip
`reservation_id` so Account can locate the matching reservation
on `commit_fill_command`).

In paper deployments paper_broker is the only producer of
`broker.order-*`; in live deployments the broker BC is the only
producer; the two never publish at the same time (broker BC's
submit-order subscriber is gated off when `--paper` is on). The
wire format is identical, so Account and execution_management
consume the same shape regardless of who produced it.

### `shared` — cross-BC kernel

`shared/lib/` holds code more than one BC depends on. Notable
inhabitants:

- `bus/` — the `Bus.Adapter` port, the `In_memory` adapter (per-topic
  Eio fiber + 1024-deep stream), and the producer/consumer
  helpers. Single-consumer-per-(uri, group) is the deliberate
  invariant for monolithic deployments; see
  `bus/adapters/in_memory/in_memory.mli`.
- `correlation_id/` — UUIDv4 newtype used as the saga routing
  key (ADR 0011 §1).
- `workflow_engine/` — the Process Manager runtime
  (`Make(WORKFLOW)(STORE)`). `Order_process_manager` is the first
  concrete instance.
- `inbound_http/` — `Route.handler` contract; per-BC
  `inbound/http/` modules compose into the trading host's HTTP
  surface.
- `gherkin_edsl/` — BDD scenario DSL used by component tests.
- `rop/` — Railway-Oriented Programming (Wlaschin) primitives.

`shared` is not a BC. It contains no domain model and publishes
no integration events. It is the "shared kernel" of Eric Evans'
DDD vocabulary — code intentionally available everywhere because
it is general-purpose, not domain-specific.

## The integration-event canon

Integration events carry primitives only (no Value Objects), use
ISO-8601 strings for timestamps, and decimals as canonical
strings (ADR 0007). Naming uses past-tense verbs with the
`_integration_event` suffix to disambiguate from domain events
(which omit the suffix and use past-tense verbs without it).

The bus is logical. URIs of the form `in-memory://<topic>` route
through `In_memory.broker`; switching to a network broker
(Kafka, Redpanda, NATS) is a one-line `Bus.register` change at
the composition root and zero changes anywhere else.

Topic conventions per BC:

| Topic                                          | Producer              | Notes                          |
|------------------------------------------------|-----------------------|--------------------------------|
| `in-memory://strategy.signal-detected`         | strategy              | Alpha mind, fresh cid          |
| `in-memory://pm.target-portfolio-updated`      | portfolio_management  |                                |
| `in-memory://pm.trade-intents-planned`         | portfolio_management  | Per-leg cid                    |
| `in-memory://pre-trade-risk.trade-intent-approved` | pre_trade_risk    | Cid echoed                     |
| `in-memory://pre-trade-risk.trade-intent-rejected` | pre_trade_risk    | Cid echoed                     |
| `in-memory://account.reserve-command`          | execution_management  | Saga-driven command channel    |
| `in-memory://account.release-command`          | execution_management  | Saga compensation channel      |
| `in-memory://account.amount-reserved`          | account               | Cid echoed                     |
| `in-memory://account.reservation-rejected`     | account               | Cid echoed                     |
| `in-memory://account.reservation-released`     | account               |                                |
| `in-memory://broker.submit-order-command`      | execution_management  | Saga-driven command channel    |
| `in-memory://broker.cancel-order-command`      | execution_management  | Saga compensation channel      |
| `in-memory://broker.order-accepted`            | broker or paper_broker | Cid echoed                    |
| `in-memory://broker.order-rejected`            | broker or paper_broker | Cid echoed                    |
| `in-memory://broker.order-unreachable`         | broker                | Cid echoed (live only)         |
| `in-memory://broker.order-filled`              | paper_broker          | Cid + reservation_id echoed    |
| `in-memory://broker.order-cancelled`           | paper_broker          | Cid + reservation_id echoed    |
| `in-memory://broker.bar-updated`               | broker                | Upstream candles               |
| `in-memory://pre-trade-risk.trade-submission-blocked` | pre_trade_risk | Telemetry on a gate halt    |
| `in-memory://pre-trade-risk.kill-switch-tripped` | pre_trade_risk | First trip of the drawdown circuit |

## The dependency rule

A BC must not import another BC's domain or application code at
the language level. The trading host (`bin/main.ml` and
`lib/infrastructure/inbound/http`) is the one exception: it
imports every BC's factory because it composes them. Cross-BC
data exchange goes through:

1. **Integration events** on the bus (the canonical channel,
   covered above).
2. **Wire-format mirrors** in each BC's
   `infrastructure/acl/external_integration_events/` — DTOs that
   look identical to the producer's outbound DTO but live in the
   consumer's library, so the BCs do not share a type.

The mirrors are duplication on purpose. Sharing a type would
re-couple the BCs at compile time and undo the structural
benefit of the boundary. Wire-shape parity is enforced by JSON
contract tests, not by the type system.

The compiler enforces (1) and (2) through dune library
boundaries: each BC's `lib/dune` lists only `core common
decimal`, `shared/`, and the BC's own libraries. Crossing the
boundary fails the build.

## The place-order saga (end-to-end happy path)

The full chain a single bar can produce, from arrival at Strategy
through fills, with `cid` denoting the saga `correlation_id`:

```
1. broker        → broker.bar-updated         (upstream candle)
2. strategy.on_candle  →  strategy.signal-detected     [cid_n]
3. PM            ← strategy.signal-detected
   PM.Define_alpha_view_command
   → Direction_changed
   → apply_proposed_targets_on_alpha_direction_changed
       (Sizing.from_strength → Risk_policy.clip → Target_portfolio.apply_proposal)
   → Target_portfolio_updated_IE
4. PM.Reconcile_command  (composition-driven, periodic)
   → diff(target, actual)
   → pm.trade-intents-planned                         [cid_n per leg]
5. pre_trade_risk     ← pm.trade-intents-planned
   Assessment.assess → Approve / Reject
   → pre-trade-risk.trade-intent-{approved,rejected}  [cid_n]
6. execution_management ← pre-trade-risk.trade-intent-approved
   Kill_switch + Rate_limit gate
   if blocked → pre-trade-risk.trade-submission-blocked
   else       → Order_process_manager.start                  [cid_n]
                → account.reserve-command              [cid_n]
7. account            ← account.reserve-command
   Reserve_command_workflow
   → account.amount-reserved | account.reservation-rejected   [cid_n]
8. execution_management ← account.amount-reserved
   Order_process_manager.transition: Awaiting_reservation → Submitted
   → broker.submit-order-command                      [cid_n]
9. broker (live) or paper_broker (--paper)  ← broker.submit-order-command
   Submit_order_command_handler.make (live) or
   Submit_order_command_workflow.execute (paper)
   → broker.order-{accepted,rejected,unreachable}     [cid_n]
10. execution_management ← broker.order-{rejected,unreachable}
    Order_process_manager.transition: Submitted → Compensated
    → account.release-command                         [cid_n]
11. account            ← account.release-command
    Release_command_workflow
    → account.reservation-released
12. paper_broker.Apply_bar_command_workflow (in --paper) or
    broker WS bridge (live) → fill events
    → broker.order-filled                             [cid_n + reservation_id]
13. account            ← broker.order-filled
    Commit_fill_command_workflow → Portfolio.commit_fill
    → account.reservation-filled                      (atomic: new cash + position + avg)
14. portfolio_management, pre_trade_risk, execution_management
    ← account.reservation-filled
    PM:   Commit_actual_fill_command_workflow → Actual_portfolio.commit_fill
    PTR:  Record_fill_command_workflow         → Risk_view.commit_fill
    EMS:  Kill_switch.update_equity (new_cash as equity proxy)
```

The pure saga transitions (steps 6, 8, 10) are pinned by
`execution_management/test/unit/order_process_manager_test.ml` against the
`Definition.transition` function — bus-free, Eio-free. End-to-end
component tests that drive the saga through the in-memory bus are
a follow-up; the pure test plus the per-BC component tests
(Account, Broker) cover the moving parts today.

## Backtest as composition

A backtest is the same composition with the synthetic broker
adapter swapped in, run against generated candles and tallied
from the outbound IE stream. The CLI (`trading backtest`) and
the HTTP endpoint (`POST /api/backtest`) share the
`run_backtest_composition` helper in `bin/main.ml`. There is no
domain `Backtest.run`, no separate engine, no separate state
machine — backtest-vs-live agreement is structural.

The full mechanics are covered in ADR 0011 §7 and in the
[testing](testing.md) page.

## Deployment shape

Today: one process. The trading host boots one `Bus.t`, registers
one `In_memory` broker as the `in-memory` scheme, and instantiates
every BC's factory. All buses are local, all subscriptions are
in-process, the saga store is in-memory.

Eventually: each BC ships as its own service. The single-process
boot is preserved for development and demo; production gets one
container per BC, talking to a Kafka-equivalent broker behind the
same `Bus.Adapter` port. Saga state moves from `In_memory_store` to a
Postgres-backed store. The transition is design-level zero
because the cross-BC code already programs against ports.

This is the ADR 0001 hexagonal payoff realised at the BC
granularity: the same code that makes `Broker.S` swappable
(Finam ↔ BCS ↔ Synthetic) makes `Bus.Adapter` swappable
(in-memory ↔ Kafka) at the next layer up. paper_broker plugs in
at the BC granularity rather than as a `Broker.S` adapter
because it is the simulated brokerage (an entire BC's worth of
ports, state, and emitted events), not a wrapper around a data
source — see ADR 0012.

## See also

- [hexagonal-architecture.md](hexagonal-architecture.md) —
  per-BC layering (domain / application / infrastructure).
- [domain-model.md](domain-model.md) — types that flow across
  the boundaries.
- [reservations.md](reservations.md) — the Account ledger's
  reserve / commit / release semantics.
- [rop.md](rop.md) — Railway-Oriented Programming, used in
  every BC's `application/commands/` workflow.
- [testing.md](testing.md) — Sociable unit tests, in-process
  component tests with Gherkin, contract tests for wire shapes.
- [ADR 0001](../adr/0001-hexagonal-architecture.md) — Hexagonal
  architecture (the layering inside each BC).
- [ADR 0009](../adr/0009-portfolio-management-bounded-context.md)
  — Why PM is its own BC, not an extension of Account.
- [ADR 0010](../adr/0010-alpha-mind-vs-bracket-exit-projection.md)
  — Why Strategy emits alpha mind, not exit imperatives.
- [ADR 0011](../adr/0011-risk-evacuation-and-place-order-saga.md)
  — The risk evacuation and the place-order saga; the BC graph
  this page describes is its end state.
