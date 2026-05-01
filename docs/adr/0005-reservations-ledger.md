# 0005. Reservations ledger for order lifecycle

**Status**: Accepted
**Date**: 2026-04-18

## Context

Pre-Phase-B, the engine updated the portfolio **optimistically**
at the moment of order submission. The code path was:

```
signal → Risk.check(portfolio.cash) → Portfolio.fill → Broker.place_order
```

`Portfolio.fill` moved cash into a position *before* the broker
had even acknowledged the order. This is the dominant pattern in
retail broker and banking products, and it's the root cause of
familiar failure modes:

- **Stale balance displays**: the app shows a balance that
  doesn't reflect inflight orders or pending transactions.
- **Double-spend windows**: a strategy sends signals on two
  consecutive bars, both pass `Risk.check` against the same
  pre-order `cash`, together they would exceed available funds.
- **Ledger drift on reject**: the broker rejects the order, but
  our optimistic update already moved cash. We'd see "Rejected"
  in logs while the portfolio claimed the trade happened.
- **Price slippage accounting**: broker fills at a different
  price than intended. Our optimistic `Portfolio.fill` used the
  intended price; cash debit doesn't match reality.

In Backtest the problem didn't manifest because there's no
broker — we *are* the reality and the optimistic fill is ground
truth. In Live with Paper the problem was masked because Paper
fills deterministically at open[T+1] with no rejections. Moving
to real brokers (Finam, BCS), the problems would surface
immediately.

The proposed mechanism: the cash required for a buy — the
position value plus a slippage allowance (only for market orders,
since limit orders fix the price) plus the commission estimate —
should enter a *pending* state. The amount is **reserved** against
the available cash but **not** debited. On the corresponding
broker fill event, the actual debit replaces the reservation.

## Decision

Split portfolio accounting into **two phases**:

1. **Reserve** at the moment of order intent. Cash and position
   quantity are *earmarked* — `available_cash` /
   `available_qty` drop, but `cash` and `positions` are
   unchanged. Risk checks consult `available_cash`, so
   back-to-back signals can't collectively overspend.
2. **Commit** when the broker confirms a fill, with actual
   numbers. Removes the reservation, applies `Portfolio.fill`
   for that slice. Partial fills shrink the reservation and
   apply a `fill` for the slice; the reservation stays open
   until remaining quantity hits zero.

A reject / cancel calls `release`, which drops the reservation
without any cash/position change.

Add these operations to `Portfolio`:

```ocaml
val reserve : t -> id:int -> side -> instrument -> quantity ->
              price -> slippage_buffer:float -> fee_rate:float -> t
val commit_fill : t -> id:int -> actual_* -> t
val commit_partial_fill : t -> id:int -> actual_* -> t
val release : t -> id:int -> t
val available_cash : t -> Decimal.t
val available_qty : t -> Instrument.t -> Decimal.t
```

Thread through `Step.execute_pending`:

```ocaml
let portfolio' = Portfolio.reserve state.portfolio
  ~id:reservation_id ~side ~instrument ~quantity ~price
  ~slippage_buffer ~fee_rate in
if config.auto_commit then
  Portfolio.commit_fill portfolio' ~id:reservation_id
    ~actual_quantity ~actual_price ~actual_fee
else
  portfolio'   (* reservation stays open *)
```

`auto_commit = true` for Backtest (reserve + commit atomic,
no broker latency). `auto_commit = false` for Live (reserve
only; wait for broker event).

Live_engine calls `Step.commit_fill` / `Step.commit_partial_fill`
/ `Step.release` from:

- `on_fill_event` — primary path, triggered by Paper's
  synchronous callback or a real broker's WS `order_update`
  frame.
- `reconcile` — fallback path, polls `Broker.get_orders`
  periodically to catch anything the primary path missed.

## Alternatives considered

### Status quo (optimistic fill)

Fails on reject, partial, and slippage. We started here; moving
to real broker made it untenable.

### Separate "expected" vs. "actual" portfolios

Keep the optimistic fill in Live and *additionally* maintain a
"broker-confirmed" portfolio updated by events. Reconcile drift
between them.

This doesn't fix the strategy's decision-making — it still asks
the optimistic portfolio for `available_cash`, which doesn't
reflect pending orders. Adds complexity without solving the
Risk gate problem.

### Pessimistic ledger: no portfolio update until broker
confirms

The cleanest correctness model: the engine's `Portfolio` is
*only* the broker's confirmed reality. Reserve with a shadow
record, check it against reality.

Works, but slower (strategy on bar T+1 doesn't know about its
order from bar T until the broker round-trip completes). Doesn't
matter for our bar-granular strategies (minutes to hours between
decisions), but constrains higher-frequency trading.

Practically equivalent to the reserve+commit approach we picked —
the reservation IS the "shadow record". The difference is just
whether Risk checks against `cash` (pessimistic) or
`available_cash = cash - reserved` (reserve+commit). We chose
the latter because it's slightly more responsive: Risk sees the
pending impact immediately.

### Event sourcing

Model the portfolio as a fold over an append-only event log.
Replay on restart, distribute across nodes, etc.

Overkill for a single-engine, single-process deployment.
Interesting if this grows to a distributed system, but we can
retrofit event sourcing on top of the reservation model without
disturbing the domain types.

## Consequences

**Easier**:

- `Risk.check` uses `available_cash` — a single point enforces
  the "no overspend across inflight orders" invariant.
- Reject path: `release` returns the reservation to the pool
  without touching real state. No cleanup, no reconciliation
  required.
- Partial fills work correctly: `commit_partial_fill` shrinks
  the reservation proportionally, maintains correct
  `available_cash` across multiple events per order.
- Backtest behavior preserved: `auto_commit = true` collapses
  reserve+commit into one atomic step, equivalent to the old
  `Portfolio.fill`.
- Differential test still passes: Paper emits fill events
  synchronously after `on_bar`, so Live commits at the same
  logical instant as Backtest's atomic reserve+commit.

**Harder**:

- Two ledgers to reason about when debugging: `cash` /
  `positions` (reality so far) vs. `available_cash` /
  `available_qty` (reality minus pending). The `.mli` exposes
  both; callers must pick the right one.
- `Portfolio.t` record gained a field. External readers that
  used to see `{ cash; positions; realized_pnl }` now see
  `{ cash; positions; realized_pnl; reservations }`. Mostly
  fine because `t` is `private` — construction goes through
  operations.
- Per-reservation state adds complexity to partial fills. The
  `per_unit_cash` field on `reservation` captures the ratio at
  reserve time so shrinking the remaining quantity scales the
  earmarked cash linearly.

**To watch for**:

- Reservations can accumulate indefinitely if `commit_fill` /
  `release` isn't called. Current safeguard: `reconcile` runs
  every `config.reconcile_every` bars and closes out terminal
  orders. If `reconcile_every = 0` (disabled), reservations
  will leak on broker restart or WS drop.
- The `reconcile` path now pulls actual per-execution numbers
  via `Broker.S.get_executions`. Paper implements this from
  its own fill history. Finam and BCS adapters have stub
  implementations (`failwith`) that will be filled in when the
  live integration lands — until then, `get_executions` fails
  for those adapters and reconcile falls back to intended
  numbers (bounded per-order drift, not accumulating). For
  Paper the path is exact.

## Consequences observed

After Phase B.4 (partial fill support) + auto-trigger of
reconcile, all 238 OCaml tests pass, including the differential
test and a new multi-bar partial-fill end-to-end test. The
reservation model added no measurable overhead in Backtest
(same lazy `Seq.t` drive loop). Live behavior on paper is
indistinguishable from the pre-reservations version — same fills,
same P&L, same order counts.

## References

- Phase B.1 commit: "Portfolio reservations data model".
- Phase B.2 commit: "Deferred commit in Live_engine".
- Phase B.3 commit: "Reconcile via Broker.get_orders".
- Phase B.4 commit: "Partial fill commits".
- [Reservations doc](../architecture/reservations.md).
- [Live engine doc](../architecture/live-engine.md).
- Prior-session design discussion: the proposed mechanism was
  "the amount is reserved but not debited" — this ADR implements
  exactly that.
