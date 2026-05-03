# 0009. Portfolio Management bounded context

**Status**: Accepted
**Date**: 2026-05-03

## Context

Existing BCs in the project:

- `account` — cash, positions, reservations, margin policy. Models
  the *observed* state of the trading book: what the system actually
  holds at a given moment, derived from broker fills and the
  reservation lifecycle. Authoritative on holdings.
- `broker` — order placement and broker-specific lifecycle through
  hexagonal adapters (Finam, BCS, synthetic, paper).
- `strategy` — single-instrument decision policies (`Strategy.S`
  with eleven concrete implementations: `bollinger_breakout`,
  `rsi_mean_reversion`, …) plus indicators, the live engine, and
  the backtester. Each strategy receives one bar stream and emits a
  single per-instrument `Signal.t = Buy | Sell | Hold`.

A class of strategies that the project intends to demonstrate —
cointegrated-pair mean reversion, β-hedging, vol-targeting,
risk-parity overlays — does not fit `Strategy.S`. They are
inherently **multi-instrument**: the decision is about the *spread*
of two legs, or about the joint allocation across a basket. The
output is not a single `Signal.t` but a vector — a desired position
per instrument, with hedge-ratio-driven sizing across legs.

Forcing such strategies into `Strategy.S` either requires
generalising the contract to a multi-bar stream and a multi-leg
signal type (invasive, touches all eleven existing strategies and
the live engine and the backtester), or producing a series of
asymmetric workarounds (one strategy decides, others are
"slaves"; or pair logic is bolted onto the execution side as a
saga). Both lose the textbook canonical pattern that the
reference application is meant to show.

A second issue: even with a generalised strategy contract, the
**execution side** of a multi-leg strategy is not a sequence of
single-instrument signals. It is a target → diff(actual, target)
→ trade-list flow, where the diff has to be computed atomically
per book. Account is the wrong place to host that — its
ubiquitous language is *holdings* (what I have), not *targets*
(what I want); its invariants are accounting invariants
(`cash ≥ 0`, reservations ≤ buying power), not portfolio-
construction invariants (target weights well-formed, hedge
symmetry preserved, risk caps respected).

The canonical decomposition for systematic trading platforms
(LEAN's Algorithm Framework, Nautilus' `Portfolio` /
`RiskEngine`, the buy-side middle-office / front-office split) is
a four-stage pipeline:

```
Alpha / Signal       →  Portfolio Construction  →  Risk          →  Execution
single-instrument        multi-instrument target    pre-trade        order
forecast / signal        portfolio (vector)         clipping         routing
```

The current codebase has Alpha (`strategy`) and a primitive
Execution (`broker` + the live engine), but no Portfolio
Construction layer at all. This ADR introduces it as its own
bounded context.

## Decision

Add a new bounded context `portfolio_management` as a peer to
`account` and `broker`. The BC owns the target-portfolio
lifecycle and the construction-time risk-shaping that goes with
it. Its boundaries are:

- **inbound**: integration events from `account` describing changes
  in the observed state (positions, cash); commands from the
  composition root that drive policy decisions and reconciliation.
- **outbound**: an integration event announcing target-portfolio
  updates; an integration event announcing the trade list emitted
  by the reconciler.

The BC's domain language has two first-class portfolio models, not
target plus view:

- `Target_portfolio` — the *intended* state of a book. Aggregate
  root with invariants on per-instrument single-valuedness,
  zero-target pruning, idempotent re-application, and book-id
  consistency.
- `Actual_portfolio` — the *observed* state of a book, projected
  from inbound integration events arriving from `account`.
  Aggregate root with invariants on delta accumulation and
  per-instrument single-valuedness.

Both are domain models with behavioural invariants. Read-side
projections of either are view-models living in the BC's
`application/queries/` layer; the view-models are the
CQRS-shaped DTOs, not the actual portfolio model itself.
`account.Portfolio` and `portfolio_management.{Target,Actual}_portfolio`
are **distinct concepts** — the BC boundary isolates the
vocabulary. `account` knows nothing about targets; PM never
mutates `account`'s ledger.

The BC follows the project's hexagonal + per-aggregate layout
(ADR 0001, 0006). Layer libraries are split per
`feedback_layer_libraries_enforced`-style enforcement, with
unidirectional compile-time deps:

```
portfolio_management/
├── lib/
│   ├── domain/                                # library `portfolio_management`
│   │   ├── shared/                            # cross-aggregate VOs
│   │   │   ├── book_id.{ml,mli,mlw}
│   │   │   ├── pair.{ml,mli,mlw}
│   │   │   ├── hedge_ratio.{ml,mli,mlw}
│   │   │   ├── z_score.{ml,mli,mlw}
│   │   │   ├── target_position.{ml,mli,mlw}
│   │   │   ├── target_proposal.{ml,mli,mlw}
│   │   │   └── trade_intent.{ml,mli,mlw}
│   │   ├── target_portfolio/
│   │   │   ├── target_portfolio.{ml,mli,mlw}  # aggregate root
│   │   │   └── events/target_set.{ml,mli,mlw}
│   │   ├── actual_portfolio/
│   │   │   ├── actual_portfolio.{ml,mli,mlw}  # aggregate root
│   │   │   ├── values/actual_position.{ml,mli,mlw}
│   │   │   └── events/{actual_position_changed,actual_cash_changed}.{ml,mli,mlw}
│   │   ├── reconciliation/
│   │   │   ├── reconciliation.{ml,mli,mlw}    # pure domain service
│   │   │   └── events/trades_planned.{ml,mli,mlw}
│   │   ├── risk/
│   │   │   ├── values/risk_limits.{ml,mli,mlw}
│   │   │   └── risk_policy.{ml,mli,mlw}       # construction-time clipping
│   │   ├── portfolio_construction.{ml,mli,mlw} # module type S
│   │   └── pair_mean_reversion/                # one S impl
│   │       ├── pair_mean_reversion.{ml,mli,mlw}
│   │       ├── values/{pair_mr_config,pair_mr_state}.{ml,mli,mlw}
│   │       └── events/target_proposed.{ml,mli,mlw}
│   ├── application/
│   │   ├── queries/                           # library .queries
│   │   ├── integration_events/                # library .integration_events
│   │   ├── domain_event_handlers/             # library .domain_event_handlers
│   │   └── commands/                          # library .commands
│   │       (set_target / change_position /
│   │        change_cash / reconcile, each as the
│   │        wire-format DTO + handler + workflow triplet)
│   └── infrastructure/
│       └── acl/inbound_integration_events/    # library .acl.inbound_integration_events
│           (forward-looking mirrors of the account-side
│            Position_changed / Cash_changed events; functorised
│            handlers Make(Bus.Event_bus.S))
└── test/
    ├── unit/
    └── component/                             # Gherkin BDD scenarios
```

Key choices that fall out of this decision are:

### Construction-policy abstraction introduced from day one

`Portfolio_construction.S` is a module type defined in
`portfolio_construction.{ml,mli,mlw}` at the domain root.
`pair_mean_reversion` includes it. The abstraction is introduced
at v1, with one concrete implementation, by direct analogy with
`Strategy.S` in the strategy BC: every Portfolio Construction
policy will be a state machine consuming bars and occasionally
emitting `Target_proposal.t`, and the reference application
demonstrates the canonical pattern even before the second
implementation lands.

### Book_id partitioning from day one

Every PM command, event, and aggregate carries `Shared.Book_id.t`.
A book is a logical partition for an independently-managed
portfolio (one book per running strategy instance, or one per
trading account in a future multi-account setup). The aggregates
are per-book; `Target_portfolio.apply_proposal` rejects
cross-book mismatch; the reconciler is strictly per-book.
Adding the partition later would mean rewriting every command and
event, so it is in from the start.

### Risk-as-policy lives inside PM

Construction-time risk clipping (per-instrument notional cap,
gross-exposure cap with proportional scaling that preserves hedge
symmetry, future drawdown haircut) is part of building the target
proposal. It lives in `domain/risk/`, applied as a transformation
`Target_proposal → Target_proposal` between the policy's emission
and the aggregate's apply.

This is **risk-as-policy**: how big a position the policy is
*allowed* to want. It is distinct from **risk-as-gatekeeper**:
pre-trade order validation, fat-finger thresholds, kill switches,
real-time drawdown breach. Risk-as-gatekeeper applies to *every*
order regardless of source — manual trades, future strategies,
debug paths — and belongs to a separate future BC. PM's risk
sub-system has soft-clipping semantics; the gatekeeper has
hard-veto semantics. Mixing them would conflate two different
failure-mode classes.

### `Actual_portfolio` is a domain model, not a CQRS read-model

The observed state of the book within PM is built from inbound
integration events, but it bears its own invariants and is the
input to `Reconciliation.diff` — a domain operation, not a
read-side query. Calling it a "view" or "projection" would
mis-classify it: views are what `application/queries/` holds;
domain models are what enforces invariants and participates in
business operations. Both `Target_portfolio` and `Actual_portfolio`
are aggregate roots; the asymmetry that one is fed by external
events does not change its model status.

### `shared/` instead of `core/` for cross-aggregate VOs

The BC depends on the external `core` library (Instrument, Side,
Candle from the strategy BC's domain). With dune
`(include_subdirs qualified)`, a sibling sub-directory named
`core/` would be wrapped as a local `Core` module that shadows
the external library inside any file that references both. The
sub-directory holding the cross-aggregate VOs is therefore named
`shared/` — same role (Eric Evans' "shared kernel" within a BC),
no name collision.

### `portfolio_construction.{ml,mli,mlw}` flat at the domain root

The module type definition lives as a flat triple at
`portfolio_management/lib/domain/`, alongside the aggregate
sub-directories (`target_portfolio/`, `actual_portfolio/`,
`pair_mean_reversion/`, `reconciliation/`, `risk/`). Placing it
inside a `portfolio_construction/` parent sub-directory next to a
`pair_mean_reversion/` child sub-directory would trigger dune's
sub-directory main-module collapse rule (ADR 0006): a child
referencing the parent's main file is rejected as a cycle. The
flat placement is the simplest correct shape — the module type
is a contract definition, not an aggregate — and it follows the
strategy BC's `strategies/strategy.{ml,mli}` precedent of placing
the abstraction next to its implementations rather than wrapping
them.

## Alternatives considered

### Merge target portfolio into the existing `account` BC

Reuse `account.Portfolio` and add target-tracking fields beside
its existing cash / positions / reservations.

Rejected because the two halves have different ubiquitous
languages (Portfolio = "what I have" vs Portfolio = "what I want
+ what I have"), different rates of change (account changes on
fills, target changes on rebalance signals), different sources of
truth (broker reconciliation vs strategy decisions), and
different invariant classes (accounting invariants vs
construction invariants). Mixing them would dilute the BC
boundary, expand `account`'s surface beyond accounting, and break
the directional dependency `portfolio_management → account`
(reads its events) into a circular one. Account's narrow
invariants and Why3-verifiable surface are exactly what should
*not* be expanded.

### Generalise `Strategy.S` to multi-instrument

Change the strategy contract so `on_bar` accepts a multi-bar
context and returns a multi-leg target.

Rejected because it touches all eleven existing strategies, the
backtester, the live engine, the indicator pipeline, the
registry, and the CLI — and ends with the same target-vs-actual
reconciliation problem that this BC solves anyway. The
multi-instrument path also conflates the alpha-generation role
(per-instrument signals) with the portfolio-construction role
(allocation across signals), which the LEAN-style canonical
decomposition keeps separate. Strategy stays single-instrument,
PM is the new layer.

### Composite-over-strategies inside `strategy`

Introduce a new combinator under `strategy/lib/domain/strategies/`
that wraps two child strategies operating on different
instruments and "coordinates" them.

Rejected because for pair mean reversion the legs are not
independent decision-makers — each leg is a deterministic
decomposition of one decision (the spread's z-score crossing).
Calling them "two strategies" inflates the meaning of *strategy*
to include "position holder", which weakens the abstraction. For
genuine multi-policy overlays (dual momentum, risk-parity across
independent alphas), the construct needed is a **portfolio
strategy** emitting a target vector — exactly what
`Portfolio_construction.S` is. The composite framing therefore
converges on the same shape, just under a different name; PM
introduces the right shape directly.

### `Actual_portfolio` as a CQRS read-model

Treat the observed state inside PM as a pure read-side projection
with no behaviour, used only as input to a stateless reconciler.

Rejected because the projection enforces invariants (delta
accumulation, single-valuedness per instrument, idempotent
apply); a read-model that enforces invariants is by definition a
domain model. Treating it as a view would also mis-classify
`Reconciliation.diff` from a domain operation into a read-side
query, blurring the layer boundaries the BC is meant to make
explicit.

### Defer the `Portfolio_construction.S` abstraction until a second policy lands

Ship pair_mean_reversion as a concrete module with no abstract
interface; introduce the module type when β-hedging or
vol-targeting arrives.

Rejected for the reference-application case: the project's role
is to demonstrate canonical patterns, and the
`Strategy.S`-with-eleven-implementations precedent makes the
abstraction the natural shape from day one. The cost of
introducing the module type now is one short file; the cost of
retrofitting it across an established `pair_mean_reversion`
public surface later is a noticeable refactor of every caller.

## Consequences

**Easier**:

- Multi-instrument strategies have a place to live without
  touching `Strategy.S` or the eleven existing strategies.
- The target-portfolio lifecycle is centralised in one BC with
  its own invariants, its own Why3 lemmas (target-portfolio
  uniqueness, reconciler idempotence, hedge_ratio positivity,
  pair-MR hysteresis), and its own component tests in Gherkin.
- Future risk-as-gatekeeper, pair-research, and execution-saga
  BCs can sit cleanly around PM through integration events
  (`Target_portfolio_updated`, `Trade_intents_planned` outbound;
  `Position_changed`, `Cash_changed` inbound) without disturbing
  account or broker.
- The `Book_id`-partitioned design lets multiple strategies run
  side by side in the future without retrofitting the BC's APIs.

**Harder**:

- One more BC to maintain — six layer libraries
  (`portfolio_management`, `.queries`, `.integration_events`,
  `.domain_event_handlers`, `.commands`,
  `.acl.inbound_integration_events`) and two test runners (unit,
  component). Per-layer dune wiring, formatting, and CI coverage
  apply uniformly.
- The duplicated `Instrument_view_model` (locally in
  `portfolio_management.queries`, mirroring the equivalent in
  `account.queries` and `strategy.queries`) is the cost of
  keeping the BC graph acyclic. Wire-shape parity is structural;
  divergence would surface in JSON contract tests.
- The forward-looking ACL adapter mirrors `Position_changed` /
  `Cash_changed` events that `account` does not yet publish.
  Until account's outbound surface grows to include them, the
  inbound branch of the saga is live but unfed.

**To watch for**:

- The `account → portfolio_management` event direction must stay
  one-way. Account knows nothing about books, targets, or the
  reconciler. If a future change tempts adding a PM type into
  account, the symmetry that justifies the BC split is broken.
- Risk-as-policy and risk-as-gatekeeper must stay distinguishable
  even within shared vocabulary (a `max_drawdown` figure can
  appear in both, but used differently — sizing on the PM side,
  hard-stop on the gatekeeper side). When the gatekeeper BC
  lands, the same numeric limit may be configured in two places;
  this is a feature, not duplication.
- `strategy/lib/domain/engine/risk.ml` and the strategy-internal
  portfolio-tracking state currently live in the strategy BC for
  historical reasons. By the decomposition adopted here they
  belong in PM (`risk/` for limits, `actual_portfolio/` for
  observed state). The relocation is deliberately deferred to a
  follow-up — the present ADR scopes only the new BC, leaving
  the strategy library untouched. The follow-up will move
  `Engine.Risk` and the live-engine portfolio state into PM, and
  reduce strategy to its alpha/signal role.
- The composition root (`bin/main.ml`) is **not** wired to PM in
  this delivery. PM builds and tests stand-alone; the saga
  plumbing (target → reconcile → trade intents → Submit_order
  with reservation → fills → Position_changed → actual_portfolio)
  is the next milestone, after the surrounding BCs are tidied.

## References

- LEAN Algorithm Framework (Alpha → Portfolio Construction → Risk
  → Execution decomposition).
- NautilusTrader's `Portfolio` and `RiskEngine` decomposition.
- Vernon, *Implementing Domain-Driven Design*, ch. 14 (Application
  Layer) and ch. 13 (Integration between Bounded Contexts).
- Wlaschin, *Domain Modeling Made Functional*, ch. 9 (Workflow
  composition with Railway-Oriented Programming).
- Cockburn, *Hexagonal Architecture* (the original ports/adapters
  paper) — adopted project-wide in ADR 0001.
- ADR 0006 — per-aggregate domain layout convention applied here
  to a multi-aggregate BC.
