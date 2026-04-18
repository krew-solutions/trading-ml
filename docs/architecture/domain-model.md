# Domain model

`lib/domain/core/` holds the vocabulary every other layer speaks.
These types are broker-agnostic by design — adapters translate
wire formats into them, so the rest of the system never sees
Finam-isms or BCS-isms.

All domain modules ship with a matching `.mli` file; the compiler
rejects any reference to an unexposed implementation detail. See
[ADR 0002](../adr/0002-mli-guardrails.md) for the rationale.

## Instrument

```ocaml
type t = private {
  ticker : Ticker.t;
  venue  : Mic.t;
  isin   : Isin.t option;
  board  : Board.t option;
}
```

Identity of a tradable asset. Wire format used on the HTTP API
and broker adapters: `TICKER@MIC[/BOARD]`, e.g. `SBER@MISX/TQBR`.

Previous iterations used a flat `Symbol.t` (string). We replaced
it because different brokers key their routing on different
fields: Finam needs `(ticker, mic)`, BCS needs `(ticker,
classCode)` where `classCode` corresponds to our `board`. A
structured `Instrument.t` captures all of them and lets each
adapter pick what it needs.

## Decimal

Fixed-point number at scale `10^-8` backed by `int64`:

```ocaml
type t = int64
let scale = 8
let unit_ = 100_000_000L
```

Prices, quantities, cash balances — everything financial goes
through `Decimal.t`. Float is never used for money-sized
quantities because the rounding would accumulate across the
equity curve. The arithmetic is explicit (`Decimal.add`,
`Decimal.mul`, `Decimal.div`), which also makes currency
operations visually distinct from loop counters and indicator
math.

`Gospel` preconditions on `Decimal.div` document the
`Division_by_zero` raise; `gospel check lib/domain/core/decimal.mli`
verifies them.

## Candle

OHLCV bar with enforced invariants:

```ocaml
type t = private {
  ts : int64;         (* open time, unix epoch seconds (UTC) *)
  open_ : Decimal.t;
  high : Decimal.t;
  low : Decimal.t;
  close : Decimal.t;
  volume : Decimal.t;
}

val make :
  ts:int64 -> open_:Decimal.t -> high:Decimal.t ->
  low:Decimal.t -> close:Decimal.t -> volume:Decimal.t -> t
(** Raises Invalid_argument when:
    - low <= open_,close <= high
    - volume >= 0 *)
```

The smart constructor is the only way to build a `Candle.t` —
`type t = private` blocks direct record construction from outside
the module. This guarantees every `Candle.t` anywhere in the
system satisfies the invariant, so downstream code doesn't need
defensive checks.

## Order

Broker-agnostic order representation:

```ocaml
type kind =
  | Market
  | Limit of Decimal.t
  | Stop of Decimal.t
  | Stop_limit of { stop : Decimal.t; limit : Decimal.t }

type time_in_force = GTC | DAY | IOC | FOK

type status =
  | New | Partially_filled | Filled | Cancelled | Rejected
  | Expired | Pending_cancel | Pending_new | Suspended | Failed

type t = {
  id : string;               (* broker's id *)
  exec_id : string;
  instrument : Instrument.t;
  side : Side.t;
  quantity : Decimal.t;
  filled : Decimal.t;
  remaining : Decimal.t;
  kind : kind;
  tif : time_in_force;
  status : status;
  created_ts : int64;
  client_order_id : string;  (* caller-controlled *)
}
```

Every broker's wire format translates to this shape in the
adapter. The `.mli` for `Order` exposes predicates
(`is_done`, `remaining_qty`) and pretty-printers; it does NOT
expose wire-format converters. Those live in the ACL adapters —
see [hexagonal ADR](../adr/0001-hexagonal-architecture.md).

Both `id` and `client_order_id` are preserved so adapters that
track orders by their own id (Finam) can do so internally, while
the `Broker.S` port consistently uses `client_order_id` as the
caller-facing key.

## Signal

What a strategy emits:

```ocaml
type action =
  | Enter_long | Enter_short
  | Exit_long | Exit_short
  | Hold

type t = {
  ts : int64;
  instrument : Instrument.t;
  action : action;
  strength : float;
  stop_loss : Decimal.t option;
  take_profit : Decimal.t option;
  reason : string;
}
```

`strength` is `0.0 .. 1.0` and flows into position sizing via
`Risk.size_from_strength`. `Hold` means "no change"; it keeps
the pipeline functional (the strategy always returns a signal,
even if nothing is happening) without producing orders.

## Portfolio

Cash + positions + realized PnL + outstanding reservations:

```ocaml
type position = {
  instrument : Instrument.t;
  quantity : Decimal.t;   (* signed *)
  avg_price : Decimal.t;  (* VWAP entry price *)
}

type reservation = {
  id : int;
  side : Side.t;
  instrument : Instrument.t;
  quantity : Decimal.t;       (* remaining *)
  per_unit_cash : Decimal.t;  (* immutable after reserve *)
}

type t = private {
  cash : Decimal.t;
  positions : (Instrument.t * position) list;
  realized_pnl : Decimal.t;
  reservations : reservation list;
}
```

The type is `private` — callers read fields but can't construct
directly. State transitions go through named operations:
`fill`, `reserve`, `commit_fill`, `commit_partial_fill`,
`release`. Each validates its inputs and raises
`Invalid_argument` on violations.

`reservations` exists to represent the gap between "broker
accepted our order" and "broker reported a fill". See
[reservations](reservations.md) for the full mechanism and
[ADR 0005](../adr/0005-reservations-ledger.md) for why.

## Side

Plain sum type, `Buy | Sell`, with helpers `to_string`,
`of_string`, `opposite`, `sign`. The opposite pairing is what
lets `Portfolio.fill` compute realized PnL when closing a
position.

## Timeframe

```ocaml
type t = M1 | M5 | M15 | M30 | H1 | H4 | D1 | W1 | MN1
```

Bar width. Maps to seconds via `Timeframe.to_seconds`; each broker
adapter maps to its own wire representation (Finam's
`TIME_FRAME_H1`, BCS's numeric codes).

## See also

- [State machine](state-machine.md) — how these types flow
  through the trading loop.
- [Reservations](reservations.md) — deep dive on the ledger
  operations.
- [Testing](testing.md) — how domain invariants are verified.
