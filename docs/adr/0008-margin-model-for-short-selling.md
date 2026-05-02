# 0008 — Margin model for short selling

## Status

Accepted.

## Context

Before this change `Portfolio.try_reserve` rejected any Sell whose
quantity exceeded the long position with `Insufficient_qty`. Opening
or growing a short was therefore impossible through the
`reserve → commit_fill` cycle, even though the fill side already
supports signed positions, VWAP, realized PnL on direction flip, and
mark-to-market equity for shorts. Strategies wanting to short had no
path through the application layer.

Real brokerage shorting is a margined operation: the broker requires
collateral (initial margin) when the short is opened, and the cap
against which collateral is checked — buying power — is not just idle
cash but the account's equity, with long positions counting toward
the cap at a haircut.

## Decision

Add a margin model to the `Portfolio` aggregate so that a Sell can be
reserved against buying power instead of just position quantity.

### Reservation shape

A reservation is split into two portions:

- `cover_qty` — closes the opposite-side existing position (Sell on a
  long). Consumes available position quantity, blocks no cash.
- `open_qty` — opens or grows a same-side position (Sell into / past
  a long opens a short; Buy is currently always pure-open in this
  round). Consumes no position quantity, blocks
  `open_qty × per_unit_collateral` cash.

A single `Reservation.t` carries both portions plus a single
`per_unit_collateral`; its identity (`id`) is stable across the
cover + open split so the cross-BC saga (broker echoes the id back)
keeps one id per logical order.

### Buying power and the gating check

```
buying_power = available_cash
             + Σ |position_qty| × mark × haircut
```

where `mark` is supplied by the caller as
`Instrument.t → Decimal.t option` (precedent: `Portfolio.equity`).
When `mark` returns `None`, the position's `avg_price` is used as a
fallback so the model degrades gracefully when no live price source
is plugged in.

`try_reserve` gating per side:

- **Buy** — bounded by `available_cash` (cash-account semantics,
  unchanged in this round). Buy-on-margin is out-of-scope.
- **Sell** — `open_qty × price × margin_pct` checked against
  `buying_power`. Failure surfaces a new error variant
  `Insufficient_margin { required; available }`.

The pre-existing `Insufficient_qty` variant is retired — under the
cover/open split a Sell can no longer be qty-bound (the cover is
naturally clamped to the long, and the open is bounded by cash, not
qty).

### Margin policy as a domain Strategy

`margin_pct` and `haircut` are per-instrument values. The domain
exposes a Strategy:

```
type Margin_policy.t = Core.Instrument.t → margin_terms
and margin_terms = { margin_pct; haircut }
```

This is a **domain-level Strategy**, not a Hexagonal Port: the
algorithm of "compute buying power, gate the reservation" is pure
domain knowledge, with no IO. Concrete data inputs (a live НСР table
from the broker, accumulated SMA state for a Reg T-style account)
will be supplied via Repository ports inside specific strategy
implementations, not via the strategy interface itself.

For this round the composition root provides a stub —
`Margin_policy.constant ~margin_pct ~haircut` — that returns the same
terms for every instrument. A live per-instrument source replaces
the stub when broker integration is wired without changing any
domain or application code.

### Cover-first partial-fill attribution

`commit_partial_fill` depletes `cover_qty` before `open_qty`. The
open portion is what holds collateral; depleting it last keeps the
collateral block stable for as long as possible during a multi-leg
fill stream.

## Consequences

- Sell can now open or grow a short via the standard
  `reserve → commit_fill` path. Strategies stop having to bypass
  the reservation step.
- `available_cash` now subtracts `reserved_cash` for both Buy and
  Sell reservations (the latter only on the open portion).
- `Reservation_view_model` is wire-breaking: drop `quantity` /
  `per_unit_cash`, add `cover_qty` / `open_qty` /
  `per_unit_collateral`. The query side has no live consumer at the
  time of this ADR.
- The `Reservation_rejected` integration event now carries the
  string `"insufficient margin: …"` for the new failure track.
- `Portfolio.try_reserve` and the corresponding command
  handler / workflow gain `~margin_policy` and `~mark` parameters.
- Strategy engine (`Step.config`) gains a `margin_policy` field;
  the backtest and live engines plug in the same constant stub at
  this stage.

## Alternatives considered

- **Cash-only collateral (B1)** — simpler but ignores long
  positions as collateral, which deviates substantively from how
  every real broker accounts buying power. Rejected.
- **avg_price proxy (B2)** — avoids a mark callback at the
  reservation step, but the proxy diverges from reality whenever the
  position has gained or lost value. Rejected; the precedent of
  `Portfolio.equity` already accepting a `mark` callback made B3 the
  natural choice.
- **Two reservations per logical order** — one for the cover
  portion, one for the short-open portion. Cleaner per-reservation
  arithmetic but breaks the cross-BC saga assumption that one
  command yields one `reservation_id`. Rejected in favour of a
  single Reservation with `cover_qty` and `open_qty` fields.
- **Full SMA / Reg T model now** — requires stateful margin
  accounting, an SMA accumulator persisted alongside the portfolio,
  and ivent-driven update hooks. The current `Margin_policy.t`
  signature is intentionally narrow enough that a future stateful
  model lives in `application/` (where it can hold an SMA repository
  port) without changing the domain interface. Out of scope here.

## Out of scope

- Maintenance margin / margin call enforcement.
- Borrow rate, hard-to-borrow, locate availability.
- Buy-on-margin (closing a short with cash discount, opening a
  long against equity).
- Live per-instrument margin/haircut source — currently the
  composition root provides a constant stub.
