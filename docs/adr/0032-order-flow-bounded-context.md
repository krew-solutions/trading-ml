# 0032. Order_flow bounded context: footprint analysis on the public tape

- Status: accepted
- Date: 2026-05-27
- Deciders: @emacsway

## Context

Until now the system consumes market data as OHLCV bars only: the
broker BC relays venue candles as `Bar_updated`, and the strategy BC's
indicators (SMA, RSI, MACD, …) fold over those candles. One of them,
the `CVD` (Cumulative Volume Delta) indicator, openly approximates
per-bar buy/sell delta from the close's position within the bar range
— its own doc comment records that "bar data carries no true bid/ask
split." That approximation is the symptom of a missing capability:
order-flow (a.k.a. footprint / cluster / volumetric) analysis, which
reconstructs, from the stream of individual trades, the volume traded
at each price split by the aggressor that caused it.

This requires data the bar feed does not carry — a tick-level **public
trade stream** with, per trade, price, size, timestamp, and the
**aggressor side**. All three supported venues are MOEX-based and
expose it: Finam (`INSTRUMENT_TRADES`, gRPC/WS, `side ∈
{SIDE_BUY, SIDE_SELL, SIDE_UNSPECIFIED}`), BCS (`dataType:2`,
`side ∈ {BUY, SELL}`), Alor (`AllTradesGetAndSubscribe`,
`side ∈ {buy, sell}`). On an order-driven continuous double auction the
trade's `side` is the aggressor's side by venue convention; the
`UNSPECIFIED` case exists for opening/closing auction crosses and
negotiated (off-book) trades, which have no initiator.

This ADR fixes the boundary and the domain model for that capability
before any application or infrastructure code is written.

## Decision

### 1. A separate `order_flow` Bounded Context

Order-flow analysis becomes its own BC, not a module inside `strategy`.
The responsibility split is sharp:

- **`order_flow`** answers *"what is the shape of the order flow"* —
  objective facts about the tape (per-price clusters, bar delta, POC,
  OHLCV reconstructed from prints).
- **`strategy`** answers *"what do I do about it"* — thresholds and
  signals.

The microstructure vocabulary (cluster, delta, POC, value area,
absorption, aggressor) is self-contained and must not leak into the
strategy domain; the data tier is also fundamentally different
(tick-level firehose vs. light signal consumption), which is the
independent-deployability argument for a BC.

**Name.** Surveying industry usage, terms fall into three families:
by chart (`footprint` — a MarketDelta trademark; `cluster` — ATAS /
OsEngine; `volumetric` — NinjaTrader; `numbers bars` — Sierra Chart),
by aggregation (`volume profile` / `market profile` — QuantConnect
Lean's `VolumeProfile` / `MarketProfile`; these carry no aggressor
split and so under-describe what we build), and by domain (`order
flow` — both an industry category and the academic term for signed
trade flow; `market microstructure`). We name the BC for the domain:
`order_flow`. `footprint`, `volume_profile`, `cvd` are then *views*
within it. `cluster` is rejected as the BC name precisely because it
collides with statistical cluster analysis — the same ambiguity that
opens any discussion of "кластерный анализ"; it survives only as a
value-object name inside the BC.

### 2. The footprint bar is an aggregate with a lifecycle, not a pure projection

A first reading suggests a footprint is "just" a deterministic
projection of an immutable trade stream — no command rejects a trade.
That framing is too shallow. The aggregate earns its keep at the
**edges**, where genuine policy decisions and invariants live:

- **Immutability after seal** — a `Sealed` bar is never mutated.
- **Partition** — each print belongs to exactly one bar.
- **Conservation** — total cluster volume equals the sum of accepted
  print sizes.
- **Late / out-of-order policy** — a print whose bucket precedes the
  open bar's bucket is *late*; the aggregate refuses it (it does not
  reopen a sealed bar). The application decides what to do (drop, log,
  metric).
- **Indeterminate-aggressor policy** — see (4).

So `Footprint` is an aggregate root with lifecycle `Forming → Sealed`
and transitions `open_ / classify / absorb / seal`, single-bar
consistency boundary. Rolling to the next bar (seal current, open
next) is sequenced by the application layer holding the current bar
per instrument — mirroring how the `Portfolio` handler holds its
state. Cross-BC duplicate-delivery idempotency stays in infrastructure
(Transactional Inbox), not the domain: an exchange print is immutable,
so a duplicate is a redelivery, not a domain event.

### 3. `Aggressor` is a distinct value object, not `Core.Side`

`Side` is the direction of an *order* and has two inhabitants.
`Aggressor` classifies an *executed print* and admits a third,
`Indeterminate`, for prints with no initiator (auction crosses,
negotiated trades; Finam's `SIDE_UNSPECIFIED`). Reusing `Side` would
erase that case and force a false buy/sell choice on directionless
volume. `Aggressor.sign` is `+1 / -1 / 0` — and the `0` is load-bearing:
it keeps auction volume in *total* but out of *delta*. (OsEngine's
`Trade.Side = Buy | Sell | None` independently arrives at the same
three-state shape.)

### 4. Indeterminate volume gets its own bucket

Each `Cluster` holds three buckets: `buy_volume`, `sell_volume`,
`indeterminate_volume`. `total` counts all three; `delta = buy − sell`
excludes the third. We surface auction/negotiated volume honestly
rather than dropping it or forcing it via a tick-rule guess — auction
volume is often the largest of the session and silently folding it into
buy/sell would corrupt POC and delta.

### 5. Time bars first, with a polymorphic boundary seam

> **Update (2026-05-30):** `Volume of Decimal.t` is now implemented
> behind this seam (no-split close policy). The seam held as designed —
> the integration event, ingest handler, workflow, strategy, and the
> `absorb`/`seal` Why3 laws were untouched; only `classify`/`open_`
> gained a `Volume` case. Two costs the original framing understated:
> `bucket_start`/`period_seconds` became partial (Time-only), and
> fold-order independence does not carry to Volume (its partition is
> arrival-order-dependent; the cluster algebra still commutes within a
> fixed bar). Exact-cap print-splitting (Lean's leftover-loop, with a
> per-bucket conservation obligation for the signed split) remains the
> documented follow-up. `Tick` is still pending.

> **Update (2026-06-02): the boundary is demand-selectable, not fixed at
> composition time.** The original framing held one boundary constant per
> BC instance (the operator's configured timeframe). That made the
> footprint timeframe an operator decision a UI could not override: a
> client wanting M1 footprints while the watchlist ran M5 got nothing.
> We now mirror broker's bar-subscription port. A
> `Watch_footprints_command` / `Unwatch_footprints_command` (the footprint
> analogue of `Watch_bars_command`, primitives-only, ATD-backed,
> fire-and-forget) lets any caller — a UI, a strategy — declare interest
> in footprints for an `(instrument, boundary)`, refcounted so concurrent
> watchers share one forming bar and a boundary stops aggregating only on
> the last release. The forming-bar store is keyed by
> `(instrument, boundary)`, and one relayed print fans into the operator's
> default boundary (always on, so headless behaviour is preserved) plus
> every watched boundary, each an independent aggregate on its own clock —
> the single-boundary ingest workflow is reused unchanged, once per
> boundary, in the ACL. The boundary's wire spelling is centralised in
> `Bar_boundary.to_token` / `of_token` (`"M5"`, `"VOL:1000"`), the one
> token shared by the command and the `Footprint_completed` integration
> event so demand and published fact name a boundary identically. Two
> pieces remain follow-ups: the public tape is still started by the
> operator watchlist (a UI watching an instrument outside it gets no
> prints until broker grows a `Watch_public_trades_command`), and the SSE
> footprint channel does not yet emit these commands on first/last
> subscriber — so today the default boundary is always on and the command
> is exercised by callers, not yet by the chart.

`Bar_boundary` is a variant; only `Time of Core.Timeframe.t` is
implemented now. `Volume` / `Tick` boundaries are the planned additions
and drop in as new cases, not a rewrite — the seam lives in the type,
exposed via `admits_time_close` (Time bars must close at the period
edge even in a silent market; Volume/Tick bars only close on the print
that crosses the threshold).

We are not claiming time bars are the better footprint substrate —
the literature (de Prado, *Financial Data Structures*) argues
volume/dollar bars normalise information content and give returns
closer to IID, and they are the intended default for footprint. We
start with Time because it is the cheapest to integrate (it reuses the
existing `Timeframe`, aligns with the broker's candle grid, and gives
a free reconciliation oracle: a Time footprint's own OHLC must agree
with the venue candle for the same period) and because the *hard* parts
of this BC are not the boundary — they are aggressor handling, the
cluster algebra and its proofs, the late-data policy, and the broker
trade relay. We hold the easy axis constant and familiar while
de-risking the hard ones. Volume bars then arrive as step 2, at which
point the print-splitting question (a single print that overflows the
volume threshold) is decided locally in the Volume close-predicate.

### 6. Objective facts here, thresholded signals in `strategy`

The `Footprint_completed` event carries objective facts only: OHLCV,
volume, delta, POC, per-price clusters. Thresholded interpretations —
stacked imbalance (≥ N%), CVD divergence — are instrument- and
regime-dependent, prone to overfitting, and belong to `strategy`, which
consumes this event. This keeps tunable parameters out of the
formally-verified core.

### 7. Relationship to the existing `strategy` CVD — duplicate, integrate later

`order_flow` produces ground-truth delta from real aggressor data;
`strategy`'s `CVD` indicator approximates it from candles. For now they
coexist (the proxy remains a valid fallback for candle-only instruments
and backtests); `order_flow` builds its delta self-contained. Per the
project's BC-isolation rule, BCs duplicate vocabulary rather than share
it, so a separate delta notion in `order_flow` is expected, not a
collision. Feeding `order_flow`'s true delta into `strategy` (making the
proxy a fallback) is a later cross-BC integration, deliberately out of
scope here.

### 8. Formal-verification scope — proved vs. tested, stated honestly

The Why3 companions prove, at the value level: the cluster algebra
(`delta = buy − sell`, `total = sum of three`, non-negativity
preserved by `add`) and **`add` commutativity** (the formal kernel of
fold-order independence — reordering prints within a bar yields the
same cluster); the print invariant (`size > 0`); and the Time-bucket
arithmetic. At the aggregate level, on the running `volume` / `delta`
accumulators that are the source of truth for the bar's totals:
**conservation** (`absorb` grows volume by exactly the print size),
the **delta law** (`delta` moves by `sign(aggressor) · size`), and the
lifecycle laws (`seal` freezes status and preserves totals).

What is *not* push-button SMT-provable, and is therefore left to
construction + tests rather than a proof, is stated plainly: the
list-sum equivalence ("sum of cluster totals equals `volume`") holds by
construction via the per-step `Cluster.add_conserves_total` law and is
covered by a QuickCheck property; POC / high / low are projections, not
invariants, and are unit-tested. This delineation is deliberate — we do
not overclaim what the proofs cover.

## Alternatives considered

**Fold order-flow into `strategy`.** Rejected: the microstructure
language is self-contained and the tick data tier is a different scale
and lifecycle. Folding it in would leak vocabulary and couple a heavy
ingestion path to the light signal path. (YAGNI argues for it; the
decomposition cost argues louder.)

**Name the BC `cluster` / `footprint`.** Rejected. `cluster` re-imports
the statistical-vs-trading ambiguity into the codebase; `footprint`
names one visualization (and is a vendor trademark) rather than the
domain. Both survive as names *inside* the BC.

**Model the footprint as a pure read-model / projection.** Rejected:
it ignores the real invariants and policies at the edges (seal
immutability, late data, indeterminate aggressor). Those are exactly
what an aggregate is for.

**Reuse `Core.Side` for the aggressor.** Rejected: it cannot express
the directionless (auction / negotiated) case, which is real on MOEX
and explicitly flagged by every venue.

**Volume/dollar bars first.** Tempting on information-content grounds,
but it couples bring-up to a still-unproven trade relay (volume bars
only close on a print), forfeits the candle reconciliation oracle, and
forces the print-splitting decision immediately. Deferred to step 2
behind the polymorphic seam, so step 1 is not throwaway.

## Consequences

**Easier:**

- A clean home for order-flow analytics with a precise remit; footprint
  / volume-profile / CVD become views within one domain.
- The formally-verified core (conservation, delta law, fold-order
  independence kernel, lifecycle) is built and proved before any I/O.
- `strategy`'s honest CVD-proxy limitation gains a real successor when
  the integration step lands.

**Harder:**

- A new data tier. The broker BC must relay a public trade stream
  (price / size / ts / aggressor) — it currently relays only bars. This
  is a hard prerequisite for the application / ACL layers.
- Backtest must move to **tick replay**: footprint needs a tape, not
  just bars. Addressed by a synthetic tape generator
  (`Synthetic.Trade_generator`) that expands each backtest candle into
  prints (reconstructing its OHLC) published on `broker.public-trade-printed`,
  so the full footprint loop runs offline. The `VirtualClock` stays on
  the bar stream — footprint uses each print's own `ts`, not ambient
  time. Caveat: the synthetic tape's delta is *generated*, so it
  validates footprint mechanics, not microstructure alpha; real
  evaluation needs a recorded live tape (a follow-up).

**To watch for:**

- The aggressor-side semantics ("does the venue's `side` mark the
  aggressor or the resting side?") is the assumption the whole delta
  pyramid rests on; an inversion would flip every delta-based signal.
  **Validated for Finam on 2026-05-27** (live SBER@MISX, via
  `broker/test/live_smoke/finam_public_trades_probe`): BUY prints sit at
  the ask and SELL prints at the bid against the L1 quote, so `side` is
  the aggressor and the `Public_trade_printed_integration_event.of_domain`
  mapping is correct. **Validated for BCS on 2026-05-28** (live
  SBER@TQBR, via `broker/test/live_smoke/bcs_public_trades_probe`):
  the `LastTrades` frame matches the inferred shape exactly
  (top-level `ticker`/`classCode`/`price`/`quantity`/`dateTime`/`side`,
  `responseType:"LastTrades"`), and BUY prints sit at the ask while
  SELL prints hit the bid — `side` is the aggressor and the
  `parse_side` mapping is correct. The few apparent "inversions"
  observed are all the same quote/trade-race L1 staleness the Finam
  probe documents (the next quote update brings the spread to match
  the trade price), not actual side inversion. **Validated for Alor on
  2026-05-29** (live SBER@MISX, via
  `broker/test/live_smoke/alor_public_trades_probe`): the
  `AllTradesGetAndSubscribe` frame matches the inferred shape exactly
  (`symbol`/`board`/`qty`/`price`/`time`/`timestamp`/`side`, lowercase
  `side:"buy"|"sell"`), and BUY prints lift the ask while SELL prints
  hit the bid against the `OrderBookGetAndSubscribe` L1 — `side` is the
  aggressor and the `parse_side` mapping is correct (agree=51,
  inverted=0; the few "ambiguous" prints are kopeck-grid in-spread
  trades, honestly classified, not inversions). **All three venues are
  now confirmed live**, so every supported tape is trusted for delta.
- A Time footprint's reconstructed OHLC may diverge from the venue
  candle (auction prints, venue filtering). Treated as an observability
  concern, not a correctness one — the footprint owns its own OHLC,
  self-consistent with its clusters.

## References

- ADR 0001 — Hexagonal architecture (the BC-independence rule).
- ADR 0006 — Per-aggregate domain layout (values / events / aggregate).
- ADR 0013 — Clock injection (time is an argument; backtest uses a
  virtual clock — here re-pointed at the trade stream).
- ADR 0014 — ATD wire contracts (for the forthcoming integration event
  and view models).
- M. López de Prado, *Advances in Financial Machine Learning*, ch. 2
  (information-driven bars) — the volume/dollar-bar rationale deferred
  to step 2.
- Lee & Ready (1991) — trade classification, the fallback when an
  explicit aggressor flag is unavailable.
- Cont, Kukanov & Stoikov — order-flow imbalance and price impact (the
  academic footing for signed order flow, distinct from footprint
  imbalance).
