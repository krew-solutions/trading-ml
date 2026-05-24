# 0028. Progressive reservation drawdown in Account

**Status**: Accepted
**Date**: 2026-05-24

## Context

ADR 0022 made `Order_process_manager` the single owner of
Account-side reservation orchestration. Its central claim about
the per-fill commit cadence (§ "Settled vs Released"):

> Saga reaches `Settled` (no command) on `Ticket_completed` —
> the per-fill commits have already drawn the reservation down
> to zero.

and, in "To watch for":

> A future operator-initiated cancel scenario would surface a
> partial-fill-then-cancel sequence. The saga handles this
> naturally today: each per-fill `Commit_fill` draws the
> reservation down, then the terminal `Ticket_cancelled`
> `Release_command` frees the remaining buffer.

The saga implements that contract correctly. In
`order_management/lib/application/process_managers/order_process_manager.ml`:

```
| Working _, Ticket_fill_recorded ev ->
    let cmd = Dispatch_commit_fill { ...; quantity = ev.fill_quantity; ... } in
    (s, [cmd])
| Working { reservation_id; _ }, Ticket_completed _ ->
    (Settled { reservation_id }, [])
```

Account does not. `account/lib/domain/portfolio/portfolio.ml`
holds **two** functions that look like the two halves of one
intent:

- `commit_fill` (lines 160-188) — removes the reservation
  unconditionally (`let p' = { p with reservations = rest }`)
  before applying `fill` with `actual_quantity`. The cover/open
  split is ignored. There is no remaining-balance check; the
  reservation is gone after a single call regardless of how
  much was actually filled.

- `commit_partial_fill` (lines 190-214) — cover-first
  attribution, shrinks `cover_qty`/`open_qty`, removes the
  reservation only when both reach zero. Raises `Not_found`
  on missing id, `Invalid_argument` on overfill. Returns
  `Portfolio.t` only — does not emit an event.

`commit_fill_command_handler.ml:78-80` calls `commit_fill`.
`commit_partial_fill` has no production caller —
`grep -rn commit_partial_fill` returns only domain definitions
and unit tests (`portfolio_test.ml`). The two functions are a
half-finished refactor; the application layer still binds the
older shape.

Effect on any OrderTicket with > 1 broker leg
(TWAP/VWAP/Iceberg/POV, or any limit order that fills in
slices):

1. First `Ticket_fill_recorded` IE → saga dispatches
   `Commit_fill_command` with leg quantity. Account removes
   the entire reservation, applies `fill` for the leg's
   quantity only.
2. Second and subsequent `Ticket_fill_recorded` IEs → handler
   gets `Reservation_not_found` from `commit_fill`; workflow
   (`commit_fill_command_workflow.ml:14`) silently drops the
   error per ADR-0022's compensation-idempotency policy. Each
   subsequent leg's cash and position delta is **lost**:
   broker has the position, Account does not.
3. `Ticket_cancelled` after partial fills → saga dispatches
   `Release_command` for the remaining buffer; the reservation
   is already gone, `release` returns `Reservation_not_found`,
   silently dropped. The cash earmark released earlier (in
   step 1) was the **full** reserved cash, not just the
   committed portion — so cash availability is over-stated
   immediately after the first leg.

The mismatch is also live for `pre_trade_risk`'s drawdown
circuit breaker (ADR 0021). The kill-switch reads equity from
Account state; partial-fill ticket flows leave equity off the
true value until a subsequent reconcile (which does not exist
today). Drawdown trip points can fire late or fail to fire.

The intent in ADR 0022 was right; the domain did not honour it.
This ADR closes the gap.

## Decision

Merge `commit_fill` and `commit_partial_fill` into one operation
with an explicit variant outcome. Every call either draws the
reservation down (it stays in the ledger with reduced cover/open
parts) or exhausts it to zero (it leaves the ledger). Each
outcome carries its own domain event. The application layer
emits the corresponding integration event.

### Domain

```ocaml
type commit_fill_outcome =
  | Drawn_down of Events.Reservation_drawn_down.t
  | Fully_committed of Events.Reservation_filled.t

type commit_fill_error =
  | Reservation_not_found of int
  | Overfill of { id : int; attempted : Decimal.t; remaining : Decimal.t }

val commit_fill :
  t -> id:int -> actual_quantity:Decimal.t ->
  actual_price:Decimal.t -> actual_fee:Decimal.t ->
  (t * commit_fill_outcome, commit_fill_error) result
```

Cover-first attribution carries over verbatim from the current
`commit_partial_fill`: a fill depletes `cover_qty` before
`open_qty`, so collateral stays blocked as long as anything is
left to open. The reservation is removed iff both parts reach
zero; that is the `Fully_committed` branch.

`Overfill` becomes a typed error rather than the existing
`Invalid_argument`. Real brokers can deliver fills that exceed
remaining quantity through rounding or in-flight cancel races;
the application layer must be able to react without raising.

`commit_partial_fill` is removed. It is dead production code,
its semantics now live inside the unified `commit_fill`. CLAUDE.md
prohibits backwards-compatibility hacks for unused code.

### New event: `Reservation_drawn_down`

Fields:

```ocaml
type t = {
  reservation_id : int;
  instrument : Core.Instrument.t;
  side : Core.Side.t;
  drawn_quantity : Decimal.t;
  fill_price : Decimal.t;
  fee : Decimal.t;
  remaining_cover_qty : Decimal.t;
  remaining_open_qty : Decimal.t;
  remaining_reserved_cash : Decimal.t;
  new_position_quantity : Decimal.t;
  new_avg_price : Decimal.t;
  new_cash : Decimal.t;
}
```

The post-image fields (`new_position_quantity`, `new_avg_price`,
`new_cash`) mirror `Reservation_filled` for the same reason
spelled out in `events/reservation_filled.mli:1-15`: a fill
atomically changes both cash and position, and downstream
consumers (PTR drawdown tracker, UI projections) need both
deltas in a single fact. Splitting them would break the
accounting identity `equity = cash + Σ qty × mark` transiently
and lead to wrong risk decisions for any reader who arrives
between the two events.

The `remaining_*` fields let consumers reconstruct the
post-image of the still-open reservation without having to
join against an earlier `Amount_reserved` and replay drawdowns.

### Application

A new IE `account.reservation-drawn-down` joins the existing
outbound topics. The workflow dispatches by outcome:

```
Drawn_down ev      → publish account.reservation-drawn-down
Fully_committed ev → publish account.reservation-filled (unchanged)
```

No saga changes; no EM/broker/paper_broker changes. The saga
already issues one `Commit_fill_command` per leg and ignores
acks; it consumes neither outbound IE.

## Alternatives considered

### Keep two functions, route by quantity in the handler

The handler could pick `commit_partial_fill` vs `commit_fill`
based on `actual_quantity == remaining`. Rejected: the choice
of "is this the terminal leg" is a domain rule (it derives
from the cover/open arithmetic), not an application-layer
heuristic. Floating around in the handler it would be fragile
against rounding and over-fill.

### Make idempotency the load-bearing fix

The original sketch added a `trade_id` field threaded EM → OM →
Account, with a `Reservation.applied_legs` set keyed by it.
Rejected on two grounds.

First, it confuses two distinct concerns: the domain bug
(`commit_fill` ignores partial-fill arithmetic) and an
infrastructure concern (at-least-once message delivery can
double-apply commands). The drawdown semantics need fixing
regardless of whether duplicates are possible; bundling the
fixes hides which change owns which symptom.

Second, it leaks the upstream BC's vocabulary into the
receiver's domain. `trade_id` belongs to broker-talk; `Account`
speaks cash / position / reservation / collateral. A receiver
aggregate that grows fields whose meaning is owned by an
upstream BC becomes structurally non-extractable into its own
microservice without dragging the upstream vocabulary along.

Idempotency under at-least-once delivery is, in this project, an
**infrastructure** responsibility delegated to the Transactional
Inbox library [ascetic-ddd-ml/lib/inbox][inbox]. Its dedup key is
`(tenant_id, stream_type, stream_id, stream_position)` — where
`stream_position` is the **aggregate's own version**. The
receiving domain never sees it; the inbox skips a duplicate
before the message reaches the subscriber.

The conceptual backing for this design: an aggregate's version
counter is a Lamport-style logical clock for events originating
from that aggregate. Across bounded contexts, the per-aggregate
logical clocks compose into a vector clock — exactly the model
the Inbox formalizes through its `causal_dependencies` metadata
(a message can declare "do not process me until these
`(stream_type, stream_id, stream_position)` triples are
processed"). This buys two properties in one mechanism:
*idempotency* (a `(stream_id, stream_position)` already seen is
silently dropped) and *causal consistency* (a downstream event
that causally depends on an upstream event is held back until
the upstream is observed processed).

Once aggregates carry versions — and most plausibly become
event-sourced as part of the same step — both `idempotency_key`
and any per-domain dedup field become redundant. PR-1 declines
to introduce a stopgap that would be removed at that point. The
domain stays clean; duplicate-delivery becomes a known,
bounded gap until the Inbox lands (tracked in "To watch for"
below and in a future ADR for the integration itself).

### Skip the new IE, only emit `Reservation_filled` at terminal

Letting `Reservation_drawn_down` legs be invisible on the bus
keeps the outbound surface narrow but breaks two consumers:
PTR cannot track equity progressively (drawdown trips with
stale equity), and any UI showing per-fill activity has
nothing to render between submit and final settlement.
Partial-fill IEs are useful exactly because they're partial;
suppressing them is a regression.

## Consequences

**Easier:**

- The saga's `Settled` semantics from ADR 0022 finally hold
  end-to-end. TWAP/Iceberg/POV cash and position reconcile
  with the broker without an out-of-band reconcile job.
- `pre_trade_risk`'s drawdown circuit (ADR 0021) sees
  per-fill equity updates and trips on the right tick.
- `commit_partial_fill` as a parallel API disappears; there
  is one way to commit a fill, with explicit outcomes.
- The `Overfill` variant gives a typed failure mode the
  application can react to (today: log + drop), instead of
  an `Invalid_argument` raise that would crash the workflow
  fiber.

**Harder:**

- Outbound surface of Account grows by one IE. Any consumer
  that thinks "a `Reservation_filled` IE = settlement of a
  ticket" must broaden its model — Account now publishes one
  or many `Reservation_drawn_down`s followed by exactly one
  terminal `Reservation_filled` per reservation.
- Two events per draw-down means double the work for an
  audit consumer wanting only terminal facts; such consumers
  should subscribe only to `Reservation_filled`.

**To watch for:**

- The "exactly one terminal `Reservation_filled` per
  reservation" invariant is currently informal — it holds
  because each fill strictly decreases `cover_qty + open_qty`
  and the terminal branch fires when both reach zero. When
  PR-4 (Why3 spec) lands, this becomes a machine-checked
  lemma. Until then, callers should treat it as a contract
  worth a unit test, not a guarantee.
- The duplicate-delivery hole stays open until the Inbox
  ([ascetic-ddd-ml/lib/inbox][inbox]) is integrated. A
  duplicated `Ticket_fill_recorded` IE today produces a
  duplicated `Commit_fill_command`, which Account would draw
  the reservation down twice against. The fix is structural
  (aggregate versioning + receive-side dedup on
  `(stream_id, stream_position)`), not local to this aggregate;
  it requires versioned aggregates across BCs and lands in a
  dedicated ADR/PR.
- `release` after a fully-drained reservation still returns
  `Reservation_not_found` (silently dropped by the
  workflow). That is the cancel-race symptom from ADR 0022's
  "To watch for"; making `release` idempotent against
  absence is PR-3.

## References

- ADR 0005 — Reservations ledger (the original `reserve →
  commit_fill / commit_partial_fill / release` shape).
- ADR 0008 — Margin model for short selling (cover/open
  split semantics that the new arithmetic preserves).
- ADR 0021 — Intake gates in pre_trade_risk (kill_switch
  consumes Account equity; correctness of per-fill drawdown
  matters here).
- ADR 0022 — Order_process_manager owns Account commit and
  release (the saga contract this ADR fulfils on the Account
  side).
- [ascetic-ddd-ml/lib/inbox][inbox] — Transactional Inbox
  library targeted for the future idempotency / causal
  consistency integration.

[inbox]: https://github.com/krew-solutions/ascetic-ddd-ml/tree/main/lib/inbox
