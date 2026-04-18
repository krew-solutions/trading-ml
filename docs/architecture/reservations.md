# Reservations ledger

The portfolio accounts for cash and positions in **two phases**:
a trade is first *reserved* (cash/qty earmarked but not moved),
then *committed* when the broker confirms the actual fill. This
closes a class of bugs inherent in optimistic accounting, which
dominates retail broker and banking products and leads to familiar
problems: stale balances, double-spending windows,
eventually-consistent disagreement between client and server.

See [ADR 0005](../adr/0005-reservations-ledger.md) for the
motivation.

## Data model

`Portfolio.t` carries an additional field beside `cash`,
`positions`, `realized_pnl`:

```ocaml
type reservation = {
  id : int;
  side : Side.t;
  instrument : Instrument.t;
  quantity : Decimal.t;         (* remaining — decreases on partial *)
  per_unit_cash : Decimal.t;    (* immutable after reserve *)
}

type t = private {
  cash : Decimal.t;
  positions : (Instrument.t * position) list;
  realized_pnl : Decimal.t;
  reservations : reservation list;
}
```

`per_unit_cash` captures the expected outlay per unit for a Buy
(price × (1 + slippage_buffer) + price × fee_rate); it's zero for
Sell since sells free cash. Stored per-reservation so a partial
fill can shrink the reservation proportionally without
recomputing from original parameters.

## Operations

```ocaml
val reserve :
  t -> id:int -> side -> instrument -> quantity:Decimal.t ->
  price:Decimal.t -> slippage_buffer:float -> fee_rate:float -> t

val commit_fill :
  t -> id:int -> actual_quantity -> actual_price -> actual_fee -> t

val commit_partial_fill :
  t -> id:int -> actual_quantity -> actual_price -> actual_fee -> t

val release : t -> id:int -> t

val available_cash : t -> Decimal.t
val available_qty : t -> Instrument.t -> Decimal.t
```

- `reserve` appends a reservation. `cash` and `positions`
  unchanged; `available_cash` / `available_qty` drop.
- `commit_fill` settles the reservation **fully**: removes it
  from the list, applies `fill` with the actual numbers. If the
  actual numbers differ from reserved, the proration works out
  automatically because only the `fill` call touches `cash` /
  `positions`, and the reservation is entirely removed.
- `commit_partial_fill` settles **part**: shrinks the
  reservation's remaining `quantity` by `actual_quantity`, applies
  `fill` for that slice. When `quantity` reaches zero the
  reservation is removed.
- `release` drops the reservation with no fill (cancel/reject).

### `available_cash`

```ocaml
let available_cash p =
  List.fold_left (fun acc r ->
    match r.side with
    | Buy  -> Decimal.sub acc (reserved_cash r)
    | Sell -> acc)
    p.cash p.reservations
```

This is what `Risk.check` uses instead of raw `cash`, so
back-to-back signals on the same bar can't collectively overspend.
A `Buy` reservation of 1000 rub reduces `available_cash` by 1000
immediately. If the bar also produces a second signal, Risk sees
only 9000 left (assuming initial 10000) and sizes / rejects
accordingly.

### `available_qty`

```ocaml
let available_qty p instrument =
  let base = match position p instrument with
    | Some pos -> pos.quantity
    | None -> Decimal.zero
  in
  List.fold_left ... subtract Sell reservations ...
    base p.reservations
```

Similarly for exits: a pending `Exit_long` locks the shares it's
selling. A second `Exit_long` on the same bar wouldn't try to sell
shares already earmarked.

## Two commit modes

`Step.config.auto_commit` controls whether the trade is committed
immediately after reservation or left pending:

```ocaml
(* inside Step.execute_pending, after Risk.Accept *)
let portfolio_r = Portfolio.reserve ... in
let portfolio' =
  if config.auto_commit then
    Portfolio.commit_fill portfolio_r
      ~id:reservation_id
      ~actual_quantity:q ~actual_price:price ~actual_fee:fee
  else
    portfolio_r     (* reservation stays open *)
in
```

- **Backtest** sets `auto_commit = true`. No broker latency to
  model; reserve and commit collapse to a single ledger move
  per bar. Behaves exactly like the pre-reservations `fill`.
- **Live** sets `auto_commit = false`. The reservation persists
  until a broker event arrives through
  `Live_engine.on_fill_event`, at which point `commit_fill` or
  `commit_partial_fill` is called with actual broker numbers.

## End-to-end flow in Live mode

```
 Pipeline.run (Step.execute_pending)
  │
  ├─ Risk.check against available_cash  → Accept q
  ├─ Portfolio.reserve ~id (available_cash drops)
  └─ emit event.settled { side; q; price; fee; reservation_id }

 Live_engine.apply_event
  │
  ├─ map cid → reservation_id (Hashtbl)
  └─ Broker.place_order ~client_order_id:cid

  ⏸ broker round-trip ⏸

 Broker fills (Paper callback / WS event / reconcile poll)
  │
  ▼
 Live_engine.on_fill_event { cid; actual_qty; actual_price; actual_fee }
  │
  ├─ find cid in pending map
  ├─ Step.commit_fill or commit_partial_fill
  └─ Portfolio.reservations shrinks, cash moves, position updates
```

## Two commit paths in Live

Live's post-Phase-B architecture at a glance: a reservation
enters the system via one entry point (`Step.execute_pending`)
and leaves through **one of two converging paths** — the primary
path driven by real broker events, and the safety-net path
driven by periodic polling.

```
                      ┌─ Step.execute_pending (reserve) ─┐
                      ▼                                   │
Pipeline ───► settled ─►│ Portfolio.reservations            │
                      │   available_cash = cash - Σ       │
                      │                                   │
                      │ submit_order:                     │
                      │   pending[cid] = {id, intended}   │
                      │   Broker.place_order              │
                      │                                   │
          ┌───────────┴───────────┐                       │
          │                       │                       │
┌─────────▼────────┐    ┌─────────▼────────┐             │
│ on_fill_event    │    │ reconcile        │             │
│ (primary path)   │    │ (safety net)     │             │
│                  │    │                  │             │
│ fires from:      │    │ polls get_orders │             │
│ - Paper callback │    │ for each cid in  │             │
│ - WS order_update│    │ pending:         │             │
│                  │    │   Filled → commit│             │
│ actual numbers   │    │   Rejected →     │             │
│                  │    │     release      │             │
└──────────────────┘    └──────────────────┘             │
          │                       │                       │
          └───────────┬───────────┘                       │
                      ▼                                   │
             Portfolio.commit_fill /                      │
             Portfolio.release                            │
                      │                                   │
                      └──────────────────────────────────┘
```

Both paths terminate in the same `Portfolio.commit_fill` /
`Portfolio.release` operations — the only difference is where the
actual numbers came from (broker event vs intended fallback) and
when it happened (synchronously vs bounded by
`reconcile_every`). Every reservation must exit through one of
the two paths eventually, or it leaks — this is why reconcile
exists as a safety net even when the primary path is reliable.

### Primary: on_fill_event

Synchronous in-process callback from Paper, or a WS `order_update`
frame from a real broker. Carries **actual** fill numbers:

```ocaml
let on_fill_event t (fe : fill_event) =
  ...
  let new_remaining = pending.remaining_quantity - fe.actual_quantity in
  if new_remaining <= 0 then
    Step.commit_fill t.state ~reservation_id ...  (* full *)
  else begin
    Step.commit_partial_fill t.state ~reservation_id ...
    Hashtbl.replace t.pending cid { pending with remaining_quantity = new_remaining }
  end
```

### Fallback: reconcile

A periodic poll of `Broker.get_orders` catches anything the
primary path missed (network drop, WS reconnect, crash recovery):

```ocaml
let reconcile_unsafe t =
  let orders = Broker.get_orders t.cfg.broker in
  List.iter (fun o ->
    match Hashtbl.find_opt t.pending o.client_order_id, o.status with
    | Some p, Filled ->
      Step.commit_fill t.state ~reservation_id:p.reservation_id
        ~actual_quantity:p.intended_quantity
        ~actual_price:p.intended_price    (* ← fallback, see caveat *)
        ~actual_fee:p.intended_fee
    | Some p, (Cancelled | Rejected | Expired | Failed) ->
      Step.release t.state ~reservation_id:p.reservation_id
    | _ -> ())
    orders
```

Auto-trigger: `Live_engine.config.reconcile_every` runs it every
N bars inside `on_bar`.

### Reconcile pulls actuals via `get_executions`

On a `Filled` status, reconcile calls
`Broker.get_executions ~client_order_id` and commits each
returned execution via `Step.commit_partial_fill` with actual
broker numbers. Paper returns its own fill history filtered by
cid; real brokers (Finam, BCS) will return per-execution trade
records (Finam's `/v1/accounts/{id}/trades`, BCS's `Deal`
list) once their adapters are wired.

If `get_executions` returns empty (adapter stub, or broker that
doesn't expose per-execution detail), reconcile falls back to
the intended numbers from the pending map. This is a
documented drift bounded by per-order slippage (typically
< 0.5% for liquid instruments) and does not accumulate — but
the ACL adapters for Finam/BCS should implement
`get_executions` before going to production so the fallback
never fires for real brokers.

## Invariants

- `cash` and `positions` always reflect *committed* reality —
  reserve doesn't touch them.
- `available_cash <= cash` always; equal when no Buy reservations
  outstanding.
- `available_qty instrument <= position.quantity` for instruments
  with Sell reservations.
- `reservations` is a plain list; `id`s are unique per engine
  instance (monotonic counter in `Step.state.reservation_seq`).
- `commit_*` raises `Not_found` on unknown id; `commit_partial`
  raises `Invalid_argument` on over-fill.

## Testing

12 unit tests in `test/unit/domain/engine/portfolio_test.ml`
cover reserve/commit/release, partial fills, `available_cash` /
`available_qty` math, and error cases. Plus end-to-end tests in
`test/unit/application/live_engine/`:

- Live_engine + Paper with `participation_rate` forces
  multi-bar partial fills; final Portfolio matches Paper's own
  ledger to six decimal places.
- Reconcile commits Filled orders, releases Rejected ones, is
  idempotent on repeated calls.
- Auto-reconcile fires after N bars.

## See also

- [State machine](state-machine.md) — where `reserve` is called.
- [Live engine](live-engine.md) — where `commit_fill` is called.
- [ADR 0005](../adr/0005-reservations-ledger.md) — why this
  model.
