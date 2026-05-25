# 0029. Single terminal commit: per-trade Trade_executed, one fill_recorded at ticket close

**Status**: Accepted
**Date**: 2026-05-25

## Context

The place-order saga settles a reservation against the actual
execution of an OrderTicket. Before this ADR the settlement path
had grown three coupled mechanisms that, together, were more than
the problem needed:

1. **The broker aggregated fills.** Each ACL adapter (Finam, BCS)
   kept a per-placement `Cumulative_sum` and shipped a
   `new_total_filled` snapshot on every `Order_filled` event. But
   the broker is a *recognizer of venue facts* (ADR 0015, Vernon's
   "external system as a source of Domain Events"), not a fill
   bookkeeper. Reconciling legs into a running total is the
   consuming aggregate's job — the OrderTicket already owns that in
   `Progress` (ADR 0017). The broker carried bookkeeping it had no
   business owning.

2. **EM emitted one `Order_ticket_fill_recorded` per leg.** A TWAP
   with 50 slices produced 50 fill-recorded IEs for one
   reservation.

3. **The saga committed per leg, fire-and-forget, and settled on
   `Ticket_completed`** (ADR 0022). To make many partial commits
   add up correctly, Account grew *progressive drawdown* — the
   `commit_fill` cover/open `Drawn_down | Fully_committed` outcome
   variant (ADR 0028).

The original, simpler intent was: **reserve once, commit once**,
at the end, with the actual executed total. A reservation is a
hold on availability; the real debit happens at settlement with
the venue's actual numbers. If settlement is a single commit of
the cumulative executed quantity, the progressive-drawdown
machinery is unnecessary and the per-leg cadence is noise.

## Decision

### 1. broker emits `Trade_executed` per trade leg, no aggregation

The per-leg fill event/IE `Order_filled` becomes `Trade_executed`,
carrying the trade only: `placement_id`, `trade_id`, `instrument`,
`side`, `quantity`, `price`, `fee`, `ts`. The `new_total_filled`
field and the `fill_*` prefixes are dropped (a trade event is
intrinsically about the trade — the prefixes were parasitic). The
adapters' `Cumulative_sum` bookkeeping is deleted. Bus topic
`broker.order-filled` → `broker.trade-executed`. paper_broker, the
simulated venue, is wire-equivalent and changes symmetrically.

The per-leg `Order.trade` record is promoted to a child Entity of
the `Order` aggregate (`Order.Trade`) with its identity field
`trade_id`: two fills with equal attributes but distinct
`trade_id`s are distinct executions and must not be conflated.

### 2. EM records one cumulative fill at ticket close

The OrderTicket aggregate's `Progress` is the single fill
aggregator. It gains `cumulative_notional` (Σ `quantity × price`)
and a `volume_weighted_average_price` accessor. EM publishes
`Order_ticket_fill_recorded` **exactly once**, on
`Ev_ticket_completed`, carrying the ticket-level totals:
cumulative filled quantity, the VWAP fill price, and total fees.
There is no per-leg fill IE.

### 3. The saga commits once and settles on `Reservation_filled`

`Order_process_manager` dispatches a single `Commit_fill_command`
for that one `Order_ticket_fill_recorded`, then waits for
Account's `Reservation_filled` to reach `Settled`
(request/response at ticket granularity). This replaces the
per-leg fire-and-forget commit and the `Ticket_completed`-driven
`Settled` of ADR 0022.

### 4. Account is unchanged; progressive drawdown goes dormant

A single commit of the full executed total (quantity == reserved
quantity) draws the reservation to zero in one step →
`Fully_committed` → `Reservation_filled`. The progressive-drawdown
path of ADR 0028 (`Drawn_down`, `commit_fill_outcome`) is no
longer exercised by this flow. It is left in place as dead code
pending a deliberate removal, rather than ripped out speculatively.

## Alternatives considered

- **Keep per-leg commits + progressive drawdown (status quo,
  ADR 0022/0028).** Correct, but it forces the broker to aggregate
  (violating its recognizer role), multiplies cross-BC traffic by
  the slice count, and makes the per-fill cadence the load-bearing
  path that every consumer must model. The single terminal commit
  is the smaller, truer model.

- **Commit the executed portion on cancel/fail too (full
  correctness for partial-then-cancel).** This would re-engage the
  `Drawn_down` path (a partial commit that leaves the reservation
  open) plus a release for the remainder — exactly the machinery
  this ADR retires. Deferred; see the gap below.

## Consequences

**Easier:**

- The broker is a pure recognizer again — no fill bookkeeping.
- One commit per reservation; Account's `Fully_committed` /
  `Reservation_filled` are the only settlement facts a consumer
  needs. Audit reasoning is proportional to one event per ticket.
- TWAP/VWAP/Iceberg/POV settle identically to a single market
  order — the slice count is invisible past the EM boundary.
- VWAP on the single commit reproduces the executed notional
  (`total × VWAP = Σ qtyᵢ × priceᵢ`), so cash and position
  averages stay exact.

**Harder / to watch for:**

- **Partial-then-cancel gap.** `Order_ticket_fill_recorded` fires
  only at full fill, so a ticket cancelled or failed after a
  partial execution commits nothing and the whole reservation is
  released — the executed portion is not reflected at Account.
  This is the known limitation of the single-terminal-commit
  model; settling a partially-executed terminal ticket needs
  either a reconcile path or a re-engagement of the (now dormant)
  partial-commit path. Tracked as future work.

- **Dead code.** ADR 0028's `Drawn_down` / `commit_fill_outcome`
  and the `account.reservation-drawn-down` IE are unreferenced by
  the live flow until either the gap above is closed (re-using
  them) or they are removed.

- **Duplicate delivery.** The single `Commit_fill_command` is
  still fire-and-forget at dispatch; the saga waits for
  `Reservation_filled` but does not deduplicate. The Transactional
  Inbox (aggregate-version dedup) remains the structural fix, as
  in ADR 0028.

## References

- ADR 0015 — Broker domain model (the recognizer role this ADR
  restores).
- ADR 0016 / 0017 — Execution-strategy abstraction and the
  OrderTicket aggregate (the sole fill aggregator).
- ADR 0022 — Order_process_manager owns Account commit and release
  (the commit-ownership stands; this ADR refines its per-leg
  cadence to a single terminal commit).
- ADR 0028 — Progressive reservation drawdown (superseded by this
  ADR; left as dead code).
