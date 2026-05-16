# 0012. Paper broker as a bounded context; matching engine in Why3-verified domain

**Status**: Accepted
**Date**: 2026-05-14

## Context

The `paper` adapter at `broker/lib/infrastructure/paper/paper/paper_broker.ml`
is labelled as broker-side infrastructure but discharges a different
role: it stands in for an entire brokerage when the real one is
unavailable (development, demo, deterministic backtests). The current
implementation conflates five concerns inside one 295-line file with a
shared `mutex` and `mutable` record:

1. **Order book of pending orders** — `book : (string * entry) list`
   keyed by `client_order_id`, with per-order `placed_after_ts`
   enforcing the no-lookahead invariant (an order placed during bar
   `T` may only fill on bars `> T`).
2. **Matching engine** — `price_if_filled` implements
   `Market | Limit lim | Stop stop` against a candle, with the
   conservative-gap convention (`open_` on gap-through, the limit
   itself on intra-bar touch).
3. **Slippage model** — `apply_slippage ~bps` with side-dependent
   sign (buys pay up, sells receive less).
4. **Fee model** — flat `fee_rate × notional`.
5. **Portfolio mutation** — `t.portfolio ← Account.Portfolio.fill t.portfolio
   ~instrument ~side ~quantity ~price ~fee` after every fill.

(5) is structurally illegal under the project's cross-BC rules. The
file's dune declaration

```
(library (name paper) (public_name trading.paper)
 (libraries core common decimal account broker)
 (flags (:standard -open Common)))
```

lists `account` as a dependency; `broker` BC therefore transitively
imports `account`. Two project invariants forbid this:

- A bounded context must not import another's domain or application
  code; cross-BC communication goes through integration events on
  the bus and through wire-format mirrors duplicated in each BC.
- An inbound integration event must not mutate the receiver's
  domain state except through a command workflow. Paper bypasses
  this by writing `Account.Portfolio` directly, dissolving the
  BC's command boundary.

Concerns (1)–(4) are genuine domain logic — gap rules, monotonic
status transitions, slippage direction, fee derivation — but they
live behind `mutable` state inside an `infrastructure/` directory.
None is Why3-checkable in the current form, and none is testable
without instantiating the full Paper record. The file's directory
label `infrastructure/paper/` is also wrong by the project's own
taxonomy: an ACL adapter translates between an internal model and
some *external* system, and Paper has no external system to translate
against — it *is* the simulated system.

There is also a vocabulary lapse to fix in this same checkpoint. The
data the simulator holds is a flat list of independent pending
orders, with no bid/ask split, no price levels, no FIFO at level, and
no opposing-order matching. The industrial term **order book**
(limit order book, LOB) denotes a venue-side structure with those
properties — LEAN reserves `OrderBook` / `DefaultOrderBook` /
`LevelOneOrderBook` for real-brokerage feeds and does not use the
term in `BacktestingBrokerage._pending`. Borrowing the term here
would mislead. The aggregate's actual identity is `Order` itself; its
collection is a repository, not an aggregate.

A further gap, dual to Paper's illegal portfolio mutation, blocks the
clean fix: **there is no fill IE on the bus**.
`account.amount-reserved`, `account.reservation-rejected`,
`account.reservation-released` exist; `broker.order-{accepted,
rejected,unreachable}` exist; an event for *"fill observed at this
price for this quantity, post the resulting position and cash
change"* does not. Without it, even a textbook ACL-driven Paper would
have no channel through which to inform Account. The same gap
explains why ADR 0011 §"to watch for" flagged Account-side
position and cash updates as "not yet emitted": upstream nobody
hands Account a fill, so the post-fill state changes have no
trigger. This ADR introduces the trigger and the single atomic
event (`Reservation_filled`) that carries the resulting state
update.

## Decision

Promote Paper to a peer BC `paper_broker` whose **domain** carries
the matching engine, slippage, and fee models as pure Why3-verified
functions; whose **application** runs the standard CQRS pipeline
(commands → workflows → domain events → DEH → integration events);
whose **infrastructure** hosts an in-memory `Order_store` adapter
behind a port that mirrors `shared/lib/workflow_engine/store.mli`.
Open the new IE channel `broker.order-filled` and the receiving
`Commit_fill_command` in Account.

The migration is atomic — a single PR — with each phase building
green before the next begins.

### 1. BC name

`paper_broker`, not `paper_brokerage` or `paper_venue`. Commit
[0b7439b](https://github.com/krew-solutions/trading-ml/commit/0b7439b)
pinned **broker = brokerage** as the project's canonical short form;
`<vendor>_broker` is the pattern for any brokerage-role BC. Paper is
a brokerage (the entity to which orders are submitted), not a venue
(the matching site to which a brokerage routes). Naming under the
existing convention pre-empts the "paper venue" reading.

### 2. Aggregate name

`Order`, not `Order_book`. The aggregate root has lifecycle (`New →
Partially_filled → Filled` or `Cancelled` / `Rejected` / `Expired`)
and identity (`client_order_id`); it is the entity whose invariants
the BC enforces. The collection of `Order` instances is a
**repository** in the DDD sense and lives in
`infrastructure/persistence/`, not under `domain/`. No cross-order
invariants exist that would justify wrapping the collection in an
aggregate — each pending order's status transitions, fill-vs-quantity
arithmetic, and no-lookahead guard are per-order.

### 3. Domain layout

```
paper_broker/lib/domain/
  order/
    values/
      placed_after_ts.{ml,mli,mlw}     -- ts ≥ 0 (no-lookahead anchor)
      order_quantity.{ml,mli,mlw}      -- > 0
      filled_quantity.{ml,mli,mlw}     -- 0 ≤ filled ≤ quantity
    events/
      order_accepted.{ml,mli,mlw}      -- DE
      order_filled.{ml,mli,mlw}       -- DE
      order_cancelled.{ml,mli,mlw}     -- DE
    order.{ml,mli,mlw}                 -- transitions, status monotonicity
  matching/
    values/fill_price.{ml,mli,mlw}     -- consistent with kind + side rules
    matching.{ml,mli,mlw}              -- pure price_if_filled
  slippage/
    values/slippage_bps.{ml,mli,mlw}   -- ≥ 0
    slippage.{ml,mli,mlw}              -- side-dependent sign, Why3-checked
  fee/
    values/fee_rate.{ml,mli,mlw}       -- 0 ≤ rate < 1
    fee.{ml,mli,mlw}
```

Order is an aggregate root with sub-directories (`values/`,
`events/`); matching / slippage / fee are domain *services* — pure
functions without state — and follow the precedent set by
`portfolio_management/lib/domain/{sizing,reconciliation,risk}` and
`pre_trade_risk/lib/domain/assessment`. The current implementation's
`apply_slippage`, `price_if_filled`, and inline fee computation move
into these services verbatim, then receive `(*@ ... *)` Why3
specifications: `Slippage.apply : Side.t -> Slippage_bps.t ->
Decimal.t -> Decimal.t` with the post-condition that
`Buy ⇒ result ≥ price` and `Sell ⇒ result ≤ price`;
`Matching.price_if_filled` with the gap-vs-touch case algebra; the
monotone status partial order on `Order` (no transition from a
terminal state).

### 4. Repository as a port

`paper_broker/lib/application/order_store.mli` defines

```ocaml
module type S = sig
  type t
  val save : t -> Order.t -> [ `Ok | `Already_exists ]
  val find : t -> client_order_id:string -> Order.t option
  val find_active : t -> Order.t list
  val update :
    t ->
    client_order_id:string ->
    f:(Order.t -> [ `Replace of Order.t | `No_change ]) ->
    [ `Updated | `Unchanged | `Not_found ]
end
```

This mirrors `shared/lib/workflow_engine/store.mli`'s atomic
read-modify-write idiom: the pure transition `f` runs under the
adapter's serialisation primitive, so domain code never sees a lock.
`find_active` is the saga-store-absent extra: the `apply_bar`
workflow scans active orders for matching against an incoming candle.
`Delete` is intentionally absent — terminal orders remain in the
repository for audit; tombstoning is a status, not a deletion.

The single in-memory adapter
`paper_broker/lib/infrastructure/persistence/in_memory_order_store.{ml,mli}`
holds a `Hashtbl.t` behind one coarse `Mutex.t`. Coarseness is
explicit and load-bearing on start: it matches the existing
implementation's all-of-`t` mutex without expanding the surface area.
The contract leaves Postgres- or Redis-backed adapters open as
future plug-ins.

### 5. Application pipeline

Three command trios, each command in its own file with handler and
workflow (`<imperative>_command{,_handler,_workflow}.{ml,mli}`,
following the project's CQRS-command naming convention):

- `submit_order_command` — validate → save fresh `Order(New)` →
  emit `Order_accepted` DE; on validation failure emit `Order_rejected`
  DE.
- `apply_bar_command` — `find_active` → for each order compute
  `Matching.price_if_filled` against the candle → if `Some price`,
  apply `Slippage.apply` → `Fee.compute` → call `update` with a
  pure transition that produces the new `Order` state and a
  `Order_filled` DE.
- `cancel_pending_order_command` — `update` with a transition that
  emits `Order_cancelled` DE if the current status is non-terminal.

Three DEHs translate DEs into IEs:

- `publish_integration_event_on_order_accepted.ml` →
  `in-memory://broker.order-accepted`
- `publish_integration_event_on_order_filled.ml` →
  `in-memory://broker.order-filled` (**new topic, this ADR**)
- `publish_integration_event_on_order_cancelled.ml` →
  `in-memory://broker.order-cancelled` (also new)

The naming pattern `publish_integration_event_on_<DE>` is the
project convention (see `account/lib/application/domain_event_handlers/`).

### 6. New IE `broker.order-filled`

```
{
  "ts": "...iso8601...",
  "correlation_id": "<saga cid, echoed>",
  "client_order_id": "...",
  "exec_id": "...",
  "instrument": "TICKER@MIC[/BOARD]",
  "side": "Buy" | "Sell",
  "quantity": "<decimal string>",
  "price":    "<decimal string>",
  "fee":      "<decimal string>"
}
```

Decimals as strings per ADR 0007. Instrument wire format per
`project_instrument_model`. `correlation_id` echoed from the
inbound `Submit_order_command` so the EMS saga can correlate the
fill against the originating trade intent.

### 7. Inbound on `paper_broker`

Two inbound channels, handled asymmetrically because IE inbound
and command-channel inbound carry different translation cost:

**IE → Command** translation needs an explicit ACL handler.
`broker.bar-updated` carries an `Bar_updated_integration_event`
(past-tense IE shape from broker BC); the local target is
`apply_bar_command` (imperative, different fields and semantics).
The translation lives in
`paper_broker/lib/infrastructure/acl/external_integration_events/
bar_updated_integration_event_handler.ml` and invokes the
`apply_bar_command_workflow` directly — by project convention an
inbound IE handler invokes the local workflow in-process without
publishing a further bus message. The pattern matches
`portfolio_management/lib/infrastructure/acl/inbound_integration_
events/bar_updated_integration_event_handler.ml` verbatim.

**Command-channel inbound** does NOT need a separate handler file.
`broker.submit-order-command` carries a wire-format
`Submit_order_command` published by the EMS saga; the local
`paper_broker.Submit_order_command` is a byte-equivalent duplicate
(per the cross-BC "duplicate, don't import" rule). No translation
between types is involved — the wire `t_of_yojson` plus the
local handler is the entire path.

This is the canonical pattern in `account/lib/factory.ml` for
the existing `account.reserve-command` and
`account.release-command` channels:

```ocaml
Bus.subscribe
  (consume ~uri:"in-memory://account.reserve-command"
     ~group:"account-saga"
     ~t_of_yojson:Account_commands.Reserve_command.t_of_yojson)
  dispatch_reserve
```

`paper_broker`'s factory subscribes to
`in-memory://broker.submit-order-command` the same way, passing
`Submit_order_command.t_of_yojson` and routing into
`Submit_order_command_handler.handle`. No file under
`infrastructure/acl/inbound_commands/` (the directory does not
exist and is not introduced by this ADR).

The asymmetry — explicit handler file for IE inbound, inline
`t_of_yojson` for command inbound — reflects the asymmetry of
the data:

| Inbound | Wire type | Local type | Translation | Site |
|---|---|---|---|---|
| `broker.bar-updated` | `Bar_updated_IE` | `Apply_bar_command` | Required | Handler file |
| `broker.submit-order-command` | wire `Submit_order_command` | local `Submit_order_command` | None (byte-equivalent) | Inline in factory |

The inline approach is deliberate, not lazy, but it relies on a
byte-equivalence invariant the project does not formally enforce
yet. When schema drift breaks that invariant — either the saga
ships a new wire version of `Submit_order_command`, or the local
command type evolves (e.g. begins carrying a parsed time-VO inside
its `Validated_*` variant while the wire still sends ISO-8601
string) — the receiving BC will need to host an explicit intake
adapter.

That adapter is **Open Host Service** in Evans's DDD vocabulary
(*Domain-Driven Design*, Strategic Design / Context Mapping), not
Anticorruption Layer. The criterion is **whose model is being
translated**, not the direction of data flow. An inbound command
belongs to the receiving BC by CQRS ownership: the receiver
defines the intent it reacts to, and senders must conform.
Translation at intake is therefore evolution of the receiver's
own *published language* — exposing our model in multiple wire
versions — which is the textbook OHS purpose. ACL exists to
defend our model from a *foreign* model; that situation does not
arise here, because the wire shape is not foreign in the first
place.

Mirror table for all four cross-BC translation cases:

| Flow | Wire model owned by | Translation | Pattern |
|---|---|---|---|
| Inbound integration event | Producer (external) | external → own | ACL |
| Outbound command | Target BC (external) | own → external | ACL |
| Inbound command | This BC (own) | wire ↔ own (one model) | OHS |
| Outbound integration event | This BC (own) | own → published | OHS |

Concrete placement when schema drift forces an intake adapter is
left as an open structural question for the future ADR that
introduces versioning: either `infrastructure/ohs/inbound_commands/
<cmd>_intake.{ml,mli}` (symmetric with `acl/`) or
`application/commands/<cmd>_intake.{ml,mli}` (closer to the
command-type itself). What this ADR commits to is the *negative*:
`infrastructure/acl/inbound_commands/` does not exist and will not
be introduced, because that location is a category error under
Evans's distinction. Outbound integration events are likewise
already an OHS realisation in the project — distributed across
`application/integration_events/` (the published-language types),
`application/domain_event_handlers/` (the DE → IE translation),
and the factory's bus-publish call — even though they are not
named OHS anywhere today.

None of the schema-drift triggers fires today: one saga, one wire
version, the command carries only primitive fields by project
convention. The inline pattern is the minimum that satisfies the
current constraints, and the upgrade path is structurally available
without code rewriting — only the addition of one file (the OHS
intake) and a factory edit when needed.

### 8. Account fill-receive side

Account gains the receiving end of the new channel:

- `account/lib/application/commands/commit_fill_command{,_handler,
  _workflow}.{ml,mli}` — validates the wire payload, looks up
  the reservation by `reservation_id`, calls
  `Account.Portfolio.commit_fill`, and reconstructs the atomic
  `Reservation_filled` domain event from the observable state
  diff (pre-image reservation + post-image portfolio).
- `account/lib/domain/portfolio/events/reservation_filled.{ml,mli}`
  — third member of the `Reservation` lifecycle alongside
  `Amount_reserved` and `Reservation_released`. The event carries
  the **entire transactional effect** of the fill: the new
  position quantity and avg-price, the new cash balance, plus
  the actual fill numbers. Splitting this into
  separate `Position_changed` + `Cash_changed` events was
  considered and rejected — see §«Atomic fill event versus
  split state-diff events» below.
- DEH publishes it as
  `in-memory://account.reservation-filled` (a single topic
  carrying the atomic fact). The previously open gap in ADR 0011
  §"to watch for" — that `account.position-changed` and
  `account.cash-changed` were promised but never emitted — is
  closed by this single channel; the per-projection IEs are
  superseded by the atomic `reservation-filled`.
- `account/lib/infrastructure/acl/external_integration_events/
  order_filled_integration_event_handler.ml` subscribes to
  `broker.order-filled` and dispatches `commit_fill_command`.
  The wire mirror keeps the producer's vocabulary
  (`Order_filled_integration_event`) because the consumer-side
  ACL renames at the *handler*, not at the mirror — the handler
  produces a local `Commit_fill_command` whose name lives in
  Account's vocabulary.

This severs the last remaining direct `Portfolio.fill` callsite
outside Account.

#### Atomic fill event versus split state-diff events

A fill simultaneously changes cash and position; the two
deltas must be visible to consumers together, or transiently
the portfolio identity `equity = cash + Σ qty × mark` is
violated. Subscribers that read in that window make wrong
decisions:

- `Risk_view` in pre-trade-risk would see "cash down, position
  same" (Buy fill, position update pending) and underestimate
  exposure, potentially approving a trade the actual portfolio
  cannot fund.
- `Kill_switch` in execution-management would see "position
  up, cash same" and register a false equity peak, then
  miss the corresponding drawdown when cash catches up.

Splitting one accounting transaction into two state-diff
events is the antipattern of "events as state diffs rather
than events as facts". The atomic event `Reservation_filled`
carries the entire transaction — both deltas plus the why
(this was a fill, not a deposit, split, or dividend). It
mirrors the existing aggregate-event idiom: `Amount_reserved`
carries the whole reservation in one payload, even though it
mutates both `cash` and `reservations`. Deposits, splits,
and dividends, when introduced, will be their own
fact-events (`Cash_deposited`, `Position_split`,
`Dividend_paid`) — generic `Position_changed` /
`Cash_changed` would lose the causal label that consumers
need to react correctly.

### 9. Composition root

`bin/main.ml`'s `--broker` flag continues to choose
`paper | finam | bcs | synthetic`. After migration:

- `--broker paper` instantiates `Paper_broker_factory.create
  ~bus ~bar_source:...` instead of the previous
  `Paper_broker.make ~source:...`. The factory subscribes the BC's
  handlers to `broker.submit-order-command` and `broker.bar-updated`
  and registers any HTTP routes via `Inbound_http.Route.handler`.
- `--broker finam | bcs | synthetic` instantiates the existing
  `Broker_factory.create` with the appropriate adapter; the broker
  BC's subscriber on `broker.submit-order-command` is the active
  one in those deployments.
- `Account_factory.create` additionally registers
  `order_filled_integration_event_handler` on `broker.order-filled`,
  unconditionally — Account doesn't care who emits the fill.

Paper used to wrap a `Broker.client` source for bar pass-through;
that direct library coupling is replaced by a subscription to
`broker.bar-updated` on the bus. The data-source brokerage is then
chosen independently of the order-flow brokerage at composition time
(e.g. paper order flow + Finam market data is a valid combination).

### 10. Cleanup

- Delete `broker/lib/infrastructure/paper/` entirely.
- Remove `account` from `broker/lib/dune` `(libraries …)`. The
  compiler now enforces the cross-BC invariant: any future
  reintroduction of `Account.*` inside `broker/lib/` fails the
  build.

## Consequences

**Architectural**

- broker BC is now what its name advertises: an ACL gateway to *real*
  brokerages (Finam, BCS, Synthetic for synthetic data; Paper is no
  longer one of its adapters). The library graph
  `broker → account` disappears, and that disappearance is
  compiler-checked.
- paper_broker BC owns a Why3-verified matching engine — a property
  that LEAN, Nautilus, and similar reference systems do not have, and
  that materially raises the formal-verification claim of the project.
- `Account.Portfolio` is mutated only through `Account`'s own command
  workflows. The "inbound IE cannot change state without a command"
  invariant is honoured uniformly.
- The new `broker.order-filled` and `account.reservation-filled`
  channels close the IE-emission gap noted in ADR 0011 §"to watch
  for". The fill arrives at Account, mutates the ledger via the
  normal command workflow, and emits a single atomic
  `Reservation_filled` IE carrying both the new cash and the new
  position. Kill-switch peak-equity and Risk_view exposure
  updates both read from this one channel.

**Operational**

- Backtest composition (synthetic broker + paper) keeps working via
  bus-coupled bar pass-through; no observable behaviour change to
  the existing backtest CLI / HTTP surface.
- Eventual paper-trading deployments with crash recovery become
  feasible via a Postgres-backed `Order_store` adapter, with no
  changes to domain or application code.

**Cost**

- One more BC to build (eight total). Composition root and topic
  table grow by a few entries.
- The `Portfolio` mutation that was a direct call becomes a
  bus-mediated round-trip. Single in-memory deployments absorb this
  cost trivially; production deployments will benefit from the
  durability guarantee that the bus mediation provides.

## Known debt

`broker/lib/application/commands/submit_order_command_handler.ml`
publishes its IE directly without a separate `_workflow.ml` file,
collapsing two responsibilities that the project's command-pipeline
convention keeps in distinct files. The violation predates this
ADR and is **not** addressed here. A follow-up PR should split
`submit_order_command_handler.ml` into handler + workflow per
convention, keeping the external IE contract unchanged.

## Out of scope

- Postgres-backed `Order_store` adapter. The port is designed to
  accommodate it; the adapter is a separate future PR with its own
  ADR if persistence semantics expand beyond the in-memory's coarse
  serialisation.
- Synthetic-as-a-BC extraction. Synthetic is a deterministic
  data-only adapter (no order matching) and remains inside broker BC
  for now. If/when it gains decision logic, the same argument that
  promotes Paper here will apply.
- Execution algorithms (TWAP, VWAP, POV, Iceberg, SOR) in EMS. The
  project's LEAN-style scope keeps EMS at defensive policies + saga,
  with execution algorithms outside the reference-app frame.
- Wiring the saga's kill-switch peak-equity update and
  pre-trade risk's exposure view to the new
  `account.reservation-filled` IE. This ADR creates the channel
  and emission; the downstream subscriptions are a separate,
  smaller PR.

## See also

- ADR 0001 — Hexagonal architecture (per-BC layering).
- ADR 0005 — Reservations ledger (Account's authoritative role).
- ADR 0006 — Domain-layer per-aggregate layout (mirrored here for
  paper_broker).
- ADR 0007 — Decimals as canonical strings on the wire.
- ADR 0009 — Portfolio Management BC (precedent for promoting code
  to a peer BC).
- ADR 0011 — Pre-trade-risk + EMS + Place_order saga (the channel
  this ADR completes).
- `docs/architecture/bounded-contexts.md` — BC graph, updated by
  the same PR to include paper_broker.
