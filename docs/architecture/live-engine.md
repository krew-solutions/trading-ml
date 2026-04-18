# Live engine

`lib/application/live_engine/live_engine.ml` bridges the pure
trading [state machine](state-machine.md) to a live broker. It
consumes a stream of bars, threads them through
`Pipeline.run`, submits orders for resulting signals, and
commits the engine's reservation ledger when broker events
confirm fills.

## Shape

The engine is a mutable wrapper around an immutable `Step.state`:

```ocaml
type t = {
  cfg : config;
  step_cfg : Engine.Step.config;
  mutable state : Engine.Step.state;
  mutable seq : int;                      (* cid counter *)
  mutable placed : Order.t list;
  pending : (string, pending) Hashtbl.t;  (* cid → reservation meta *)
  mutable bars_since_reconcile : int;
  mutable peak_equity : Decimal.t;           (* kill-switch *)
  mutable halted : bool;                     (* kill-switch *)
  mutable recent_order_ts : float list;      (* rate-limit *)
  mutex : Mutex.t;
}
```

Config:

```ocaml
type config = {
  broker : Broker.client;
  strategy : Strategies.Strategy.t;
  instrument : Instrument.t;
  initial_cash : Decimal.t;
  limits : Engine.Risk.limits;
  tif : Order.time_in_force;
  fee_rate : float;
  reconcile_every : int;
  max_drawdown_pct : float;            (* kill-switch, 0.0 disables *)
  rate_limit : (int * float) option;   (* (max_orders, window_seconds) *)
}
```

The `step_cfg` derived inside `make` has `auto_commit = false` —
Live defers every commit until a broker event arrives.

## Bar ingestion

Two entry points:

### `on_bar` — synchronous (tests, one-bar drivers)

```ocaml
let on_bar t c =
  with_lock t (fun () ->
    Stream.of_list [c]
    |> Engine.Pipeline.run t.step_cfg t.state
    |> Stream.iter (apply_event t);
    t.bars_since_reconcile <- t.bars_since_reconcile + 1;
    if t.cfg.reconcile_every > 0
    && t.bars_since_reconcile >= t.cfg.reconcile_every then
      reconcile_unsafe t)
```

One-bar pipeline invocation. Used in unit tests.

### `run` — streaming (production)

```ocaml
let run t ~source =
  Eio_stream.of_eio_stream source
  |> Engine.Pipeline.run t.step_cfg t.state
  |> Stream.iter (fun event ->
    with_lock t (fun () -> apply_event t event))
```

Drains an `Eio.Stream.t` of candles through the same pipeline. In
`bin/main.ml` this is spawned as a daemon on the server's switch,
with the WS bar bridge pushing candles into the `Eio.Stream`.

## Order submission

`apply_event` is called per `Pipeline.event`:

```ocaml
let apply_event t event =
  let strat_name = Strategies.Strategy.name t.state.strat in
  t.state <- event.state;
  match event.settled with
  | Some (_sig, settled) -> submit_order t ~strat_name settled
  | None -> ()
```

`submit_order`:

```ocaml
let submit_order t ~strat_name settled =
  let cid = next_cid ... in
  Hashtbl.replace t.pending cid {
    reservation_id = settled.reservation_id;
    intended_quantity = settled.quantity;
    remaining_quantity = settled.quantity;
    intended_price = settled.price;
    intended_fee = settled.fee;
  };
  try
    let o = Broker.place_order t.cfg.broker ~client_order_id:cid ... in
    t.placed <- o :: t.placed
  with e ->
    Hashtbl.remove t.pending cid;
    t.state <- Engine.Step.release t.state
      ~reservation_id:settled.reservation_id
```

Client order id format: `eng-<broker>-<strategy>-<unix_ts>-<seq>`.
Unique per engine instance, stable across broker restarts (seq
resets, ts monotonic).

The `pending` map bridges the broker's world (keyed by cid) to
the engine's world (keyed by reservation_id). Populated before the
broker call so if Paper's synchronous on_fill fires from inside
`place_order`, the lookup succeeds immediately.

On submission failure the reservation is released and the cid map
cleaned up — cash becomes available again for subsequent signals.

## Safety gates

Before every `Broker.place_order`, `submit_order` consults
`check_gates`:

```ocaml
let check_gates t : [ `Allow | `Drop of string ] =
  if t.halted then `Drop "kill switch tripped"
  else if not (rate_limit_ok t) then `Drop "rate limit exceeded"
  else `Allow
```

A `Drop` releases the reservation and logs the reason; a second
signal from the strategy on a later bar will try again. An
`Allow` records the order's timestamp (for rate-limit windowing)
and proceeds to the broker.

Two gates are implemented; the pattern is extensible — any new
invariant (position concentration cap, session window, circuit
breaker on consecutive rejects) fits as another branch in
`check_gates`.

### Kill switch — drawdown

`update_drawdown`, called on every `apply_event` before
`submit_order`, tracks peak equity and trips `halted = true`
when

```
(peak - current) / peak > config.max_drawdown_pct
```

Equity is marked to the current bar's close. Peak equity
updates on new highs; once the switch trips, it stays tripped
until `reset` is called deliberately. Tripping DOES NOT affect
reservations already in flight — those continue to receive
fill events and commit normally via `on_fill_event` or
`reconcile`. Only **new** order submissions are blocked.

Typical production values: `max_drawdown_pct = 0.10..0.20`.
`0.0` disables the switch.

`Live_engine.reset t` clears the flag and re-baselines
`peak_equity` to the current equity — intended as a deliberate
human operation after investigating the cause.

### Rate limit — order throughput

`rate_limit_ok` prunes `recent_order_ts` to entries within
`config.rate_limit`'s window and checks the count:

```ocaml
let rate_limit_ok t =
  match t.cfg.rate_limit with
  | None -> true
  | Some (max_orders, window_seconds) ->
    let cutoff = Unix.gettimeofday () -. window_seconds in
    let recent = List.filter (fun ts -> ts >= cutoff) t.recent_order_ts in
    t.recent_order_ts <- recent;
    List.length recent < max_orders
```

Protects against runaway strategies (a bug that emits 1000
Enter_longs on one bar would be rate-limited) and against
broker API quotas. `None` disables.

Dropped orders release their reservation, so over-production
of signals doesn't leak cash.

## Fill event path

### Primary: `on_fill_event`

Called by Paper's `on_fill` callback (or, in future, a WS
`order_update` handler):

```ocaml
let on_fill_event t fe =
  with_lock t (fun () ->
    match Hashtbl.find_opt t.pending fe.client_order_id with
    | None -> Log.warn "unknown cid"
    | Some p ->
      let new_remaining = p.remaining_quantity - fe.actual_quantity in
      if new_remaining <= 0 then begin
        Hashtbl.remove t.pending fe.client_order_id;
        t.state <- Engine.Step.commit_fill t.state
          ~reservation_id:p.reservation_id
          ~actual_quantity:fe.actual_quantity
          ~actual_price:fe.actual_price
          ~actual_fee:fe.actual_fee
      end else begin
        Hashtbl.replace t.pending fe.client_order_id
          { p with remaining_quantity = new_remaining };
        t.state <- Engine.Step.commit_partial_fill t.state ...
      end)
```

Distinguishes partial vs full fill by comparing the event's
`actual_quantity` to the pending's `remaining_quantity`. The
pending entry is either shrunk (partial) or removed (full).
Multiple partial events on one cid are handled correctly —
remaining quantity decreases with each until it hits zero.

### Fallback: `reconcile`

Periodic poll of `Broker.get_orders` for drift recovery:

```ocaml
let reconcile_unsafe t =
  t.bars_since_reconcile <- 0;
  let orders = Broker.get_orders t.cfg.broker in
  List.iter (fun (o : Order.t) ->
    match Hashtbl.find_opt t.pending o.client_order_id with
    | None -> ()
    | Some p ->
      match o.status with
      | Filled -> commit with p.intended_*
      | Cancelled | Rejected | Expired | Failed -> release
      | _ -> leave alone)
    orders
```

Auto-triggered every `config.reconcile_every` bars inside
`on_bar`. Uses intended numbers for commit — see
[reservations caveat](reservations.md#caveat-reconcile-uses-intended-prices).

## Wiring Paper

In `bin/main.ml`:

```ocaml
match paper_t, engine_t with
| Some p, Some e ->
  Paper.Paper_broker.on_fill p (fun f ->
    Live_engine.on_fill_event e {
      client_order_id = f.client_order_id;
      actual_quantity = f.quantity;
      actual_price = f.price;
      actual_fee = f.fee;
    })
| _ -> ()
```

Paper synthesizes fills on `on_bar` and fires the callback
synchronously. Live_engine commits the reservation. Because
Paper runs on its own mutex and Live_engine on a separate one,
there's no re-entrance deadlock.

## Mutex strategy

- All reads and writes of `t.state` / `t.pending` go through
  `with_lock` except one internal code path: `reconcile_unsafe`
  assumes the caller already holds the lock (used by `on_bar` for
  auto-trigger).
- `Mutex` is `Stdlib.Mutex` (non-reentrant). The submit → broker →
  fill callback loop is designed to **not** reenter: Paper's
  callback runs under Paper's mutex, not Live's, so the inner
  `on_fill_event`'s `with_lock` acquires a different lock. In
  tests that use a synchronous recording broker, the callback is
  deferred via a queue + explicit `flush` to avoid reentrance.

## External observation

Snapshot accessors, all locked:

```ocaml
val position : t -> Decimal.t
val portfolio : t -> Engine.Portfolio.t
val placed : t -> Order.t list
```

Return instantaneous snapshots. The engine runs in a fiber;
querying from another fiber is safe due to the mutex.

## See also

- [State machine](state-machine.md) — what `Pipeline.run` does.
- [Reservations](reservations.md) — the ledger the engine
  commits against.
- [Streams](streams.md) — the `Eio.Stream → Seq.t` boundary.
- [Testing](testing.md) — differential and partial-fill tests.
