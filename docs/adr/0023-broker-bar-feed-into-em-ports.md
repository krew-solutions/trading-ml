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

## Alternative considered — pull-by-Specification

A reviewer (20+ years of architectural practice) raised a
competing shape that this ADR did not initially compare
against, and which deserves to be on the record. Transcribed
here as a separate block; the chosen design above stands, but
the alternative is preserved so a future revisit can pick it
up without re-deriving the analysis.

### The reviewer's proposed flow

```
broker.bar-updated (IE)
  → ACL handler
  → Apply_bar_command { instrument, timeframe, candle }
  → Apply_bar_command_workflow:
        spec = Has_directive_consuming_bars
                 ∧ Matches_instrument(instrument)
                 ∧ Matches_timeframe_for_strategy(timeframe)
                 ∧ Status_is_working
        for ticket in Ticket_store.find_by_specification(spec):
            Order_ticket.on_volume_bar ticket ~bar ~now
            put ticket; publish events
```

This is *pull from store by Specification*. The chosen design
above is *push to subscribed callbacks*. These are two
legitimate branches of the same decision tree, paying in
different currencies.

### Where pull-by-Specification is genuinely better

1. **No lifecycle bookkeeping.** The chosen design keeps a
   registry `(instrument, timeframe) → callbacks` that must
   stay synchronised with the ticket lifecycle. On
   `Ev_ticket_opened` — subscribe; on terminal events —
   unsubscribe. Every missed call produces either a leak
   (subscription on a dead ticket) or a silent loss (ticket
   open, but not subscribed). Pull-by-spec always queries the
   current store state — no parallel source of truth.

2. **Specification as a first-class re-usable domain object.**
   The same spec works in an HTTP query "list all open POV
   tickets on SBER 1m", in a test, in an admin tool. A
   subscription registry is infrastructure, not domain — it
   does not generalise.

3. **Symmetry with other driver-commands.**
   `Advance_strategy_clock_command` naturally asks for the
   same pull-by-spec: "find all non-terminal tickets whose
   strategy consumes `Tick` — TWAP, VWAP, IS". Pull-by-spec
   unifies all driver-commands (bar, clock, future feeds).

4. **Cleaner transactional semantics.** ACL → one
   `Apply_bar_command`. The chosen design produces N commands
   (one per matching ticket). N independent transactions are
   safer for failure isolation (one failure does not topple
   others); a single transaction is more coherent for "one
   bar — one atomic unit of work over a set of tickets" and
   makes aggregate-level "Bar_applied" DEs simpler.

5. **Replay-friendly.** On bar replay (bus replay, crash
   recovery) pull-by-spec just re-applies to the current
   store state. The chosen design needs the registry to
   survive a crash or be rebuilt from tickets — additional
   recovery work.

### Where the chosen design is genuinely better

1. **O(1) vs O(N) per bar.** Bars are a high-selectivity
   stimulus: of 6 strategies only POV consumes volume, then a
   further instrument+timeframe filter narrows further. On
   1000 open tickets ~10 are POV-shaped, of which ~2 match by
   key. Push-registry gives O(1) Hashtbl lookup; pull-by-spec
   scans all 1000. Not a theoretical difference — bars arrive
   often.

2. **Cold store.** With push, the store is read only when a
   workflow really mutates a ticket. With pull, the store is
   read on *every* bar, even one nobody needs. Under
   persistent storage (Postgres) this overhead becomes
   material; indices help but are not free.

3. **Native fit for push-streams.** When (if) a real
   streaming feed lands (Finam WS / Kafka), it is already a
   push shape: "subscribe by topic". The chosen port maps
   onto this naturally. Pull-by-spec wraps push into a queue,
   then ACL unwraps it back into a pull cycle — extra layer.

### Decisive factor — stimulus selectivity

- **Highly selective stimulus** (bars: ~1 of 6 strategies,
  then instrument+timeframe): push with an indexed routing
  key wins.
- **Low selectivity stimulus** (clock ticks: 4 of 6
  strategies, no further filter): pull-by-spec wins, since
  almost every ticket matches and indexing buys nothing.

### Possible hybrid (not implemented)

A combined form may be the right end state:

- `Apply_bar_command` driven by a Specification (for cheap
  predicate composition over the open ticket set).
- `Volume_feed_port` retained only as transport from external
  push-streams (live broker feed), with its output funnelled
  into the *same* `Apply_bar_command`. The port becomes
  transport; routing-to-tickets goes through the spec.

In that form O(1) indexing need not be lost: a cache
`(instrument, timeframe) → ticket_ids` lives next to the
store, invalidated on `Ev_ticket_opened` / terminal events,
and answers the spec in O(1). The *entry into the domain*
stays a single command + a single spec; lifecycle
bookkeeping reduces to "help the store answer its own spec
quickly" rather than "maintain a parallel registry with its
own contract".

### Why the current design ships first

- The push-registry form is already wired, tested, and
  reachable end-to-end for POV — the bar-feed integration
  task delivers on the immediate scope.
- Pull-by-spec is a genuine alternative, not a correction;
  picking it requires introducing a Specification facility
  and a `Ticket_store.find_by_specification` method, both of
  which are real additions that should be motivated by more
  than this single driver-command.
- The decisive factor (stimulus selectivity) cuts the *other*
  way for bars (highly selective) but cuts toward pull-by-
  spec for clock ticks (low selectivity). When
  `Advance_strategy_clock_command` is wired live, the choice
  there should be informed by this analysis.

The chosen design is preserved; the alternative is recorded
for the next revisit.

## References

- ADR 0016 — Execution strategy abstraction (`Volume_bar` /
  `Price_quote` inputs and the deferred-adapter design pattern).
- ADR 0017 — OrderTicket aggregate + OMS/EMS layering.
- ADR 0015 — Broker bounded context (owner of the bar feed).
- Evans, *Domain-Driven Design*, Ch. 9 — Specification pattern.
- Hohpe & Woolf, *Enterprise Integration Patterns* —
  Publish-Subscribe Channel, Content-Based Router, Message
  Filter (the EIP siblings of Specification).
