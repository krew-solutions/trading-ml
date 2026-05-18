# 0023. Broker bar feed into execution_management — one subscriber, two ports

- Status: accepted
- Date: 2026-05-19
- Deciders: @emacsway

## Context

Volume- and price-aware execution strategies inside
`execution_management` (POV today; future adaptive VWAP and
adaptive Implementation Shortfall; ticket-level mark-to-market in
the operator view) need access to market data. The hexagonal
port surface already models this as two ports:

- `Volume_feed_port` — per-instrument cumulative volume bars,
  consumed by POV.
- `Market_data_port` — per-instrument top-of-book / quote
  stream, consumed by Implementation Shortfall (adaptive
  variant) and by future mark-to-market projections.

Until this ADR both adapters were `Disabled` stubs — they
registered subscribers and never emitted. POV was observably
blocked rather than silently inert, but no real bar source was
wired.

The broker bounded context already publishes an OHLCV bar feed
as an integration event on the `in-memory://broker.bar-updated`
topic (one IE per bar, fields: instrument, timeframe, candle =
ts/open/high/low/close/volume). That single wire shape carries
both volume and price; the architectural choice is how the
shape lands inside `execution_management`.

## Decision

EM subscribes to `in-memory://broker.bar-updated` with a single
ACL handler that **fans out one wire bar into two typed
deliveries**:

```
                            ┌─── Volume_bar.t ──→  Broker_volume_feed
broker.bar-updated  →  ACL ─┤
                            └─── Market_data_quote.t ──→  Broker_market_data
```

The ACL handler
(`Bar_updated_integration_event_handler.handle`) is the only
place that knows the bar's wire shape; downstream consumers see
only the port-typed VOs. One bus subscription, two ports, two
independent subscriber registries.

The previous `Disabled_*` adapters are replaced by live
`Broker_volume_feed` and `Broker_market_data`. Both adapters are
passive callback registries: the ACL pushes via `deliver`,
subscribers attach via `subscribe` / `unsubscribe`. The adapters
do not own the bus subscription — bus plumbing stays in
`Factory.build`. This isolation makes the adapters unit-testable
without bus infrastructure.

### Wire→typed mapping

- `Volume_bar.t = { ts; volume }` is built from
  `candle.ts` (ISO8601 → epoch seconds via `Datetime.Iso8601.parse`)
  and `candle.volume` (decimal string → `Decimal.t`). A negative
  volume drops the delivery; the Volume_bar invariant
  `volume ≥ 0` is enforced at the boundary, not inside the
  adapter.
- `Market_data_quote.t = { ts; bid; ask; realised_volatility }`
  is synthesised from a bar by taking `bid = ask = candle.close`
  (single last-trade quote) and `realised_volatility = 0`. A
  bar with `close ≤ 0` drops the quote delivery; the Market
  data quote invariant `bid > 0 ∧ bid ≤ ask` is enforced at
  the boundary.

The bid = ask = close approximation is the standard "no
top-of-book, only last-print" degradation. When a richer
top-of-book feed lands, it replaces `Broker_market_data` without
moving the port surface.

### Per-ticket subscription lifecycle

The volume feed is consumed by tickets running a POV strategy.
The factory wires:

- `Ev_ticket_opened e` with `e.directive = Pov params` →
  `Volume_feed.subscribe ~instrument:e.intent.instrument
    ~timeframe:params.timeframe
    ~on_bar:(fun bar -> dispatch_volume_bar ~ticket_id bar)`.
  Subscription handle stored keyed by ticket_id.
- `Ev_ticket_completed / _cancelled / _failed` →
  `Volume_feed.unsubscribe` and cleanup.

`dispatch_volume_bar` packs the bar into the typed
`Ingest_volume_bar_command` and invokes the existing
`Ingest_volume_bar_command_workflow` under the factory's
mutex — the per-ticket workflow path is the same one that
existed when the command was scaffolding; this ADR fills in its
upstream driver.

The market-data adapter is live but has no per-ticket
subscriber today. The motivation for wiring it now is twofold:
(1) future consumers (adaptive IS, mark-to-market projection)
add one `subscribe` line instead of first having to build feed
infrastructure; (2) one ACL handler with two `deliver` calls is
strictly simpler than splitting into two subscribers later.

### Timeframe in POV params

`Pov_params` gains an explicit `timeframe : string` field. The
volume-feed adapter filters bars at the boundary so the
strategy only receives bars at its chosen cadence. Different
POV tickets can therefore participate at different timeframes
independently. The wire parser
(`Open_order_ticket_command_handler.parse_directive`) requires
the `timeframe` field for POV directives — a POV ticket without
it is rejected at the ACL.

## Consequences

**Easier:**

- POV is now reachable end-to-end against any live broker that
  publishes bars. Volume_feed_port is no longer observably blocked.
- The two-port abstraction holds at the wire boundary too: bar
  carries both signals, ACL splits them, consumers stay
  decoupled. When a real top-of-book feed lands, only
  `Broker_market_data` changes.
- The `Market_data_port` is wired, available, and trivially
  attachable for follow-up consumers (mark-to-market, adaptive
  strategies).

**Harder:**

- The bid = ask = close synthesis is a degraded quote. It is
  honest enough for mark-to-market (latest close is a reasonable
  mark) but adaptive IS using real bid/ask spread will need
  either a separate top-of-book feed or an enriched bar.
  `realised_volatility = 0` is a placeholder — proper rolling
  realised-vol computation lives in a follow-up (either a
  separate stateful adapter or a quote-stream feed).
- The factory now mutually references `publish_aggregate_event`
  and `dispatch_volume_bar` (let-rec). This is a small piece of
  cognitive load but localised; no global state.

**To watch for:**

- Bars from broker arrive on whatever thread the bus delivers
  on. The per-ticket Volume_feed callback enters
  `dispatch_volume_bar` which acquires the factory's mutex
  before invoking the workflow. So bar processing serialises
  against broker-IE handling — correct, but worth remembering
  if bar throughput grows.
- POV `timeframe` is per-ticket explicit; if a strategy spec
  ever requires multi-timeframe input (e.g. tracking 1m for
  pacing and 5m for trend), Volume_feed will need either
  multiple subscriptions per ticket or a richer per-callback
  filter.

## References

- ADR 0016 — Execution strategy abstraction (`Volume_bar` /
  `Price_quote` inputs and the deferred-adapter design pattern).
- ADR 0017 — OrderTicket aggregate + OMS/EMS layering.
- ADR 0015 — Broker bounded context (owner of the bar feed).
