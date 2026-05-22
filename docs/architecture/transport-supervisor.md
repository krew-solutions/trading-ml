# Transport supervisor

`broker/lib/infrastructure/acl/common/transport_supervisor.ml`
holds the WS-primary / REST-fallback pattern that broker ACL
adapters use to keep `Broker.event` flowing across WS
disconnects. It is the answer to the port contract documented
on `Broker.event` itself:

> Adapter encapsulates the transport (WS push, REST poll,
> synthetic generator, replay) — the same callback fires
> regardless of which path delivered the event.

Concretely: when the WebSocket bridge loses its connection,
the supervisor activates a REST poll fiber. When the WS
reconnects, the supervisor runs one synchronous catch-up poll
over the disconnect gap, then puts the poll fiber back to
sleep. Downstream consumers see a continuous stream; they do
not know which transport produced any given event.

## State machine

Each supervisor instance owns three pieces of state:

```ocaml
mutable poll_active : bool;   (* true ⇒ REST poll fiber ticks *)
mutable last_ts : int64;      (* cursor for catch-up windows *)
mutable stopped : bool;       (* tear-down latch *)
```

Three states, three transitions:

```
       ┌─────────────────┐   WS first connect succeeded
       │ INIT (poll on)  │ ──────────────────────────────┐
       └─────────────────┘                               │
              │                                          ▼
              │ initial WS connect failed       ┌──────────────────┐
              │ (Resilient in backoff)          │ WS_HEALTHY       │
              ▼                                 │ (poll dormant)   │
       ┌─────────────────┐                      └──────────────────┘
       │ WS_DOWN         │ ◄───────────────────────┐           ▲
       │ (poll on)       │   Resilient                         │
       └─────────────────┘   on_disconnect                     │
              │                                                │
              │ Resilient on_reconnect:                        │
              │   1) catch-up poll over (last_ts, now)         │
              │   2) flip poll dormant ────────────────────────┘
```

The invariant is **`ws_healthy ⇒ ¬poll_active`** — the two
transports never run simultaneously by design. WS health is
not inferred from traffic (a quiet channel ≠ a dead channel);
it is signalled explicitly through three calls a bridge wires
into its WS layer:

| Caller | Supervisor call | Effect |
|---|---|---|
| WS bridge after initial connect | `ws_came_up` | `poll_active ← false` |
| `Websocket.Resilient.on_disconnect` | `ws_went_down` | `poll_active ← true` |
| `Websocket.Resilient.on_reconnect` | `ws_reconnected` | one synchronous catch-up poll over `(last_ts, now)`, then `poll_active ← false` |

Initial state on `start` is `poll_active = true`, `last_ts =
initial_since_ts`. This means polling begins immediately so an
adapter that comes up before its WS is connected still surfaces
events through REST.

A second fiber runs the steady-state poll loop. On each tick it
checks `poll_active`; if false, it sleeps and loops; if true,
it calls the user-supplied `poll_window ~since_ts:last_ts
~to_ts:now` and funnels the result through the same dedup +
emit pipeline as the WS branch.

## What the supervisor does not own

Three things stay with the caller, by design:

1. **The WS bridge.** The supervisor never opens, closes, or
   reads from a socket. It only observes lifecycle transitions
   the bridge feeds it through `ws_came_up` / `ws_went_down` /
   `ws_reconnected`.
2. **The `Stream_dedup` table.** The caller passes a
   `dedup_accept : 'event -> bool` closure. Typically the
   closure binds a `Stream_dedup.t` instance the adapter holds
   on its own type, so the same dedup state can be observed by
   non-supervised code paths (an OHS publisher, a snapshot
   query, a manual reconcile).
3. **The final `emit` callback.** The adapter passes its own
   dispatch closure, which often does extra work
   (cumulative-sum bump, view-model projection) before
   producing the `Broker.event`.

The result is a polymorphic value:

```ocaml
val start :
  env:Eio_unix.Stdenv.base ->
  sw:Eio.Switch.t ->
  label:string ->
  poll_interval:float ->
  ts_now:(unit -> int64) ->
  poll_window:(since_ts:int64 -> to_ts:int64 -> 'event list) ->
  ts_of_event:('event -> int64) ->
  dedup_accept:('event -> bool) ->
  emit:('event -> unit) ->
  initial_since_ts:int64 ->
  'event t
```

The supervisor is parametric on `'event`; the same type covers
bars, fills, and any future per-symbol or per-account stream.

## The dedup invariant

Both branches funnel events through one closure:

```
WS push ──┐
          ├─► absorb ─► dedup_accept ─► (advance last_ts) ─► emit
REST poll ┘
```

The bridges that wrap the supervisor (`Bcs.Ws_bridge`,
`Bcs.Order_event_bridge`, `Finam.Ws_bridge` plus
`Finam_broker.dispatch_ws_event`) all route through
`Transport_supervisor.feed_ws`, and the supervisor's poll fiber
calls the same internal `absorb` for REST-derived events. The
single shared `dedup_accept` closure means:

- Catch-up replays after reconnect cannot double-count fills
  the WS already delivered.
- Steady-state poll during WS-down cannot double-emit when WS
  comes back and the same event arrives both ways within the
  reconnect window.
- A late WS frame whose ts < the polled tail is suppressed
  with no further work.

The discriminator the dedup uses must be **stable across both
transports**. For bars this is trivially the candle's
structural equality (`Candle.equal`). For fills the situation
is messier because BCS REST `get_deals` does not surface a
per-leg `tradeId` and Finam REST `account_trade` strips
`trade_id` from the wire payload. Both adapters compromise by
keying on `placement_id` and comparing values on
`(fill_quantity, fill_price)` — the only fields both
transports always agree on. The comment on `fill_dedup` in
each adapter calls this out as a soft limitation; surfacing
`trade_id` from REST is a follow-up cleanup.

## Wiring under two socket models

Real brokers come in two transport shapes, and the supervisor
adapts to both. The count of supervisors is symmetric (N for
bars + 1 for fills per adapter); only the disconnect-fan-out
mechanism differs.

### Socket-per-subscription: BCS market data

BCS opens **one WebSocket per (instrument, timeframe)**. Each
socket belongs to exactly one bar subscription. The
`Resilient.config` for that socket can capture the
subscription's supervisor directly in closure:

```ocaml
on_disconnect = (fun () -> Transport_supervisor.ws_went_down sup);
on_reconnect  = (fun () -> Transport_supervisor.ws_reconnected sup);
```

The bridge keeps a parallel map `supervisors :
Candle.t Transport_supervisor.t SubMap.t` alongside `conns`,
keyed by the same `(instrument, timeframe)`. Unsubscribe
removes both and stops the supervisor. No separate listener
registry is needed — the socket-to-supervisor mapping is 1:1.

For BCS fills the picture is even simpler: one account-wide
WS, one fill supervisor. The supervisor is created inside
`Bcs_broker.start_live_feed` and the `Order_event_bridge`
callback closes over it directly.

### Multiplexed socket: Finam

Finam runs **one WebSocket carrying every subscription** —
bars for any number of `(instrument, timeframe)` pairs plus
the account-wide trades stream. A single disconnect must
notify **every** active supervisor at once. There is no
1:1 socket-to-supervisor capture available.

`Finam.Ws_bridge` therefore carries an explicit listener
registry:

```ocaml
type listener_id = int

val register_lifecycle :
  bridge ->
  on_disconnect:(unit -> unit) ->
  on_reconnect:(unit -> unit) ->
  listener_id

val unregister_lifecycle : bridge -> listener_id -> unit
```

The bridge's own `Resilient.config` callbacks fan over the
registered listeners on every transition. Each supervisor
(one per bars subscription plus the fill supervisor)
registers at creation and unregisters at tear-down.

Because the multiplexed `on_event : Ws.event -> unit` cannot
know upfront which supervisor a particular `Bars b` belongs
to, `Finam_broker.dispatch_ws_event` routes by lookup:

```ocaml
| Bars b ->
    match SubMap.find_opt (b.instrument, b.timeframe) t.bar_supervisors with
    | Some sup -> List.iter (Transport_supervisor.feed_ws sup) b.bars
    | None     -> Log.info "[finam ws] bars for unregistered key — dropping"
```

So the supervisors live on the broker (`finam_broker.t`)
rather than on the bridge: the broker is the routing point.

## Catch-up windows

`ws_reconnected` calls `poll_window ~since_ts:last_ts
~to_ts:now` once, synchronously. Whether this fully covers a
long outage depends on the broker's REST endpoint:

| Broker | Stream | REST endpoint | Cursor support |
|---|---|---|---|
| BCS | bars | `Rest.bars ~n` | **none** — returns last N bars regardless. `n=20` covers ~20 minutes on M1, ~20 hours on H1. Long gaps on short timeframes can lose intermediate bars; the steady-state poll loop fills in piecemeal while WS is down. |
| BCS | fills | `Rest.get_deals ?from_ts ?to_ts` | precise cursors |
| Finam | bars | `Rest.bars ?from_ts ?to_ts ?n` | precise cursors |
| Finam | fills | `Rest.get_trades ?from_ts ?to_ts` | precise cursors |

The BCS-bars asymmetry is documented in
`bcs/ws_bridge.ml` and is the one place this pattern leaks a
broker-specific compromise into the shape of the abstraction.

## Known limitations

- **REST-branch fills carry placeholder instrument / side.**
  Both `Bcs.Rest.get_deals` and `Finam.Dto.account_trade`
  return only `(order_num, ts, qty, price, fee)`; instrument
  and side are not surfaced. The REST branch fills in
  `Instrument.make "UNKNOWN" "MISX"` and `Side.Buy`. Dedup
  keys on `(qty, price)` only, so this does not cause double
  emission — but if a REST-branch fill wins the race against
  the WS one, downstream sees the placeholder. The fix is to
  store the domain `Instrument.t` and `Side.t` on
  `Placement_handle_store` at submit time; deferred.
- **`ws_came_up` fires after the SUBSCRIBE message, not after
  the server's ack.** If a subscription is silently rejected
  by the broker (auth scope, unknown symbol), the supervisor
  may treat the socket as healthy and dormant the poll
  fiber. The supervisor would only realise something is wrong
  on the next reconnect. Acceptable for current scope —
  silent subscribe failures are not a common BCS / Finam
  pattern — but worth keeping in mind.
- **Listener registry on Finam is unbounded.** Per
  subscription the list grows by one entry and shrinks by one
  on unsubscribe. The fan-out cost is `O(N)` in active
  subscriptions, fine for the few-dozen subscriptions we
  envisage.

## See also

- [Bounded contexts](bounded-contexts.md) — the Broker BC and
  where its adapters sit.
- [Live engine](live-engine.md) — the consumer of
  `Broker.event`. Does not know which transport produced any
  given event; that opacity is what this pattern preserves.
- `broker/lib/infrastructure/acl/common/transport_supervisor.mli`
  — the API reference.
- `broker/lib/infrastructure/acl/common/stream_dedup.mli` —
  the deduplicator the supervisor delegates to.
