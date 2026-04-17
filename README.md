# Trading — OCaml algo-trading system with Finam Trade

Functional algorithmic-trading platform in OCaml with an Angular 21 front-end.
Strategies and indicators are first-class, hot-swappable, each lives in its
own file, and critical bookkeeping (decimal math, portfolio, candle
invariants) carries [Gospel](https://github.com/ocaml-gospel/gospel) specs
for formal verification.

## Layout

    lib/
      core/            Decimal, Symbol, Timeframe, Candle, Side, Order, Signal
      indicators/      Indicator framework + 19 indicators
      strategies/      Strategy framework + 4 strategies
      engine/          Portfolio, Risk, Backtester
      finam/           Finam Trade connector (REST, WebSocket, DTO)
      server/          HTTP API exposing data/backtests to the UI
    bin/               CLI entry point
    test/
      indicators/      One test file per indicator
      test_*.ml        Decimal / portfolio / backtest / finam-DTO tests
    ui/
      mock-server.mjs  Zero-dep Node mock backend (mirrors the OCaml API)
      src/app/
        indicators/    One file per indicator + overlay renderer + spec
        chart.component.ts   Multi-pane lightweight-charts wrapper
        app.component.ts     Signals-based root component

## Indicators (19)

Price-only: **SMA, EMA, WMA, RSI, MACD, MACD-Weighted, Bollinger Bands**
OHLCV: **ATR, OBV, A/D, Chaikin Oscillator, Stochastic, MFI, CMF, CVI, CVD,
Volume, VolumeMA**

Every indicator exists symmetrically on both sides:

    lib/indicators/<name>.ml              ↔  test/indicators/<name>_test.ml
    ui/src/app/indicators/<name>.ts       ↔  ui/src/app/indicators/<name>.spec.ts

Strategies (4): **SMA crossover, RSI mean-reversion, MACD momentum,
Bollinger breakout**.

## Build & test (OCaml)

    opam install . --deps-only --with-test      # one-off
    dune build
    dune runtest                                 # 57 tests

Verify Gospel specifications on the critical `.mli` files:

    gospel check lib/core/decimal.mli
    gospel check lib/core/candle.mli

Specifications carried today:

| File                       | Spec kind                                                    |
| -------------------------- | ------------------------------------------------------------ |
| `lib/core/decimal.mli`     | `div` raises `Division_by_zero`                              |
| `lib/core/candle.mli`      | `make` invariants: `low ≤ open,close ≤ high`, `volume ≥ 0`   |
| `lib/engine/portfolio.mli` | `fill` preconditions (quantity > 0, fee ≥ 0) — documented    |

The portfolio `.mli` uses cross-library types (`Core.Instrument.t`); Gospel's
load-path resolution for dune-wrapped libraries is limited, so those
specs are documentation-grade rather than machine-checked. JSON encodings
live in `*_json.ml` companion files to keep the verified `.mli` free of
Yojson dependencies.

## Run the OCaml backend

    dune exec -- bin/main.exe list
    dune exec -- bin/main.exe backtest SMA_Crossover --n 500
    dune exec -- bin/main.exe serve --port 8080          # synthetic broker

### Picking a broker

`serve --broker <id>` selects the data source. `<id>` is one of
`synthetic` (default), `finam`, or `bcs` — all three implement the
same `Broker.S` port, so every code path (candles, SSE stream,
backtest) is identical regardless of choice.

    # Synthetic (default) — deterministic random walk, no credentials.
    # Good for demos and working on UI / strategies offline.
    dune exec -- bin/main.exe serve

    # Finam: long-lived portal secret → short-lived JWT (handled by Auth)
    export FINAM_SECRET=eyJ…          # from https://tradeapi.finam.ru portal
    export FINAM_ACCOUNT_ID=1440399   # optional
    dune exec -- bin/main.exe serve --broker finam

    # BCS: OAuth2 refresh_token → short-lived access_token (Keycloak flow)
    export BCS_SECRET=eyJ…            # "Trade API" token from «БКС Мир инвестиций» → «О счёте» → «Токены API»
    export BCS_ACCOUNT_ID=00000000    # optional
    dune exec -- bin/main.exe serve --broker bcs

Credentials may come from the `--secret` / `--account` flags or
from per-broker env vars (`<BROKER>_SECRET` / `<BROKER>_ACCOUNT_ID`).
`--broker synthetic` ignores credentials.

Live brokers also attach a WebSocket bridge — `/api/stream` SSE
subscribers are multiplexed onto an upstream WS subscription, so UI
updates arrive instantly rather than on the polling cadence.
Synthetic has no WS path; its random-walk adapter wobbles the
trailing bar on each poll and the SSE stream emits the diff.

## Run the UI

The UI targets **Angular 21** with zoneless change detection, signals-based
reactivity, the `@if`/`@for` control flow, and `input()`/`viewChild()`
component APIs. `lightweight-charts` v5 draws candlesticks and secondary
indicator panes.

    cd ui
    npm install                 # one-off — Angular 21 / Vitest 4 / TS 5.9

Then pick one of three dev modes:

    npm start                   # Angular dev-server only → http://localhost:4200
    npm run mock                # Node mock backend only  → http://127.0.0.1:8080
    npm run dev                 # both, concurrently — quickest iteration

The Angular dev server proxies `/api → 127.0.0.1:8080`, so `npm run dev`
gives a fully working app without touching OCaml. Swap in the real
backend by stopping `npm run mock` and running `dune exec -- bin/main.exe
serve` on the same port.

### Mock server

`ui/mock-server.mjs` is a ~200-line, zero-dependency Node HTTP server that
mirrors the OCaml API shape (`/api/indicators`, `/api/strategies`,
`/api/candles`, `/api/backtest`). Candles are generated from a seeded
`mulberry32` keyed by `(symbol, n)`, so reloads produce identical data.
Backtest results are plausible random values. Catalog entries are a
hand-kept mirror of `lib/indicators/registry.ml` and
`lib/strategies/registry.ml` — update in both places when adding.

### Multi-pane chart

`chart.component.ts` groups overlays by their `pane` key:

- `'price'` — drawn on the main candlestick chart (SMA, EMA, WMA, Bollinger)
- any other string — a dedicated secondary pane below
  (`rsi`, `macd`, `macd-w`, `stoch`, `mfi`, `atr`, `obv`, `ad`, `cvd`, `cmf`,
   `cvi`, `chaikin_osc`, `volume`)

The price pane gets `setStretchFactor(3)`; each secondary pane gets `1`,
so the main chart stays dominant. Histogram series (volume bars) are
rendered via lightweight-charts `HistogramSeries`, with per-bar color
(green on bullish intra-bar, red on bearish). Volume and VolumeMA share
the `volume` pane by design — the MA line overlays its own bars.

### UI tests

Under **Vitest 4** (Angular 21's default) with jsdom:

    cd ui && npm test           # 20 files, 70 tests

Test layout:

- `indicators/<name>.spec.ts` — math + overlay glue per indicator
- `api.service.spec.ts` — HTTP surface via `HttpTestingController`
- `app.component.spec.ts` — signal-driven reactivity (catalog seeding,
  toggles, candle reloading on symbol change, backtest result storage).
  `ChartComponent` is overridden with a stub so lightweight-charts never
  touches jsdom's missing canvas.
- `test-setup.ts` polyfills `matchMedia` / `ResizeObserver` for jsdom.

## Adding a new indicator

Three files, three lines of glue:

1. Create `lib/indicators/my_ind.ml` implementing `Indicator.S`.
2. Create `test/indicators/my_ind_test.ml` covering the invariants via Alcotest.
3. Add one line to `lib/indicators/registry.ml`.

Mirror on the UI side:

1. Create `ui/src/app/indicators/my_ind.ts` with the pure math +
   `myIndOverlay()`.
2. Create `ui/src/app/indicators/my_ind.spec.ts` with Vitest cases.
3. Register it: one line in `ui/src/app/indicators/overlay.ts`
   (`overlayRegistry`) and one in `ui/src/app/indicators/index.ts` barrel.
4. Add a catalog entry to `ui/mock-server.mjs` so the mock exposes it.

`app.component.ts` doesn't need to change — it dispatches generically on
the pane key via `overlayRegistry`.

## Adding a new strategy

1. Create `lib/strategies/my_strategy.ml` matching `Strategy.S`:
   - **types** `params`, `state`;
   - **values** `name : string`, `default_params : params`,
     `init : params -> state`,
     `on_candle : state -> Instrument.t -> Candle.t -> state * Signal.t`.
2. Add one line to `lib/strategies/registry.ml`.
3. Add a catalog entry to `ui/mock-server.mjs`.

## Strategy composition

Individual strategies (`SMA_Crossover`, `RSI_MeanReversion`,
`MACD_Momentum`, `Bollinger_Breakout`) can be combined via
`Composite` — itself an implementation of `Strategy.S`, so
composites are indistinguishable from leaf strategies: they can be
backtested, registered in the UI, or nested into other composites.

### Voting policies

| Policy | Rule | Hold semantics |
|--------|------|----------------|
| `Unanimous` | all children must emit the same action | Hold = "no" (counts against) |
| `Majority` | >50% of all children | Hold = "no" |
| `Any` | at least one active voter | Hold = abstain |
| `Adaptive` | Sharpe-weighted ensemble | weight = max(0, rolling Sharpe) |
| `Learned` | logistic-regression meta-learner | P(profitable) > threshold |

Exit signals always take priority over Enter — safer for live
trading: close first, then decide whether to re-enter.

### Adaptive (Sharpe-weighted)

Each child tracks a virtual position and accumulates a rolling
window of realized returns. Per-child weight is proportional to
`max(0, Sharpe ratio)`. Children performing well get louder votes;
poorly-performing ones are silenced. When all Sharpes are
non-positive, falls back to equal weights (1/N).

    let strat = Strategy.make (module Composite) {
      policy = Adaptive { window = 50 };
      children = [sma; rsi; macd; boll];
    }

### Learned (logistic regression meta-learner)

A lightweight ML layer trained offline, deployed as a fixed weight
vector. No external dependencies — pure OCaml float arithmetic.

**Feature vector** (for N children): `2·N + 2` floats:

    [| signal₁(±1); strength₁; signal₂; strength₂; …;
       volatility;   (* std(close)/mean(close) over last 20 bars *)
       volume_ratio  (* current_volume / mean(volume) *)           |]

The two market-context features let the model learn regime-dependent
combinations ("SMA + RSI works in low-vol, but not high-vol") that
per-strategy Sharpe weighting cannot capture.

**Training** (`lib/domain/strategies/trainer.ml`):

    let result = Trainer.train
      ~children:[sma; rsi; macd; boll]
      ~candles:historical_data
      ~lookahead:5     (* target: is close[i+5] > close[i]? *)
      ~epochs:10
      () in
    (* result.weights  : float array   — learned coefficients
       result.train_loss / val_loss    — log-loss on 70/30 split
       result.n_train / n_val          — sample counts            *)

Walk-forward discipline: the target at bar `i` looks at
`close[i+lookahead]`, so the training set uses only bars whose
outcome is fully determined within the training window. No future
information leaks into the model. The dataset is split 70/30
(train/validation) chronologically, never shuffled.

**Deployment:**

    let strat = Strategy.make (module Composite) {
      policy = Learned { weights = result.weights; threshold = 0.6 };
      children = [sma; rsi; macd; boll];
    }

At each bar the model computes `P(profitable long)`:
- `P > threshold` → `Enter_long` with `strength = P`
- `P < 1 - threshold` → `Enter_short` with `strength = 1 - P`
- otherwise → `Hold`

**Modules:**

| File | Purpose | Lines |
|------|---------|-------|
| `logistic.ml` | `sigmoid`, `predict`, `sgd_step`, `train` (multi-epoch SGD with L2 regularisation) | ~50 |
| `features.ml` | `extract : signals → candle → recent_closes → float array` | ~35 |
| `trainer.ml` | `train : children → candles → result` (walk-forward, 70/30 split) | ~70 |
| `composite.ml` | `Learned` policy branch in `on_candle` | ~15 (delta) |

**Risks and mitigations:**
- *Overfitting* — L2 weight decay (`l2` parameter) + train/val split.
  With 4 children the model has 11 parameters; 200+ decision-point
  bars are needed for a reasonable fit.
- *Non-stationarity* — retrain periodically (e.g. weekly) on a
  sliding window. The weights are a plain `float array`; swapping
  them is a config change, not a code change.
- *Lookahead bias* — enforced structurally: `Trainer.train` never
  lets a bar's target depend on data outside the training window.

### Pre-registered composites

| Name | Children | Default policy |
|------|----------|----------------|
| `Composite_SMA_RSI` | SMA Crossover + RSI MR | Majority |
| `Composite_SMA_MACD` | SMA Crossover + MACD Momentum | Majority |
| `Composite_All` | all four strategies | Majority |
| `Adaptive_All` | all four strategies | Adaptive(window=50) |

## Broker adapters

All adapters implement the shared `Broker.S` port (`lib/application/broker/`)
so the rest of the codebase programs against `Broker.client`. WebSocket
plumbing (frame codec, TLS handshake, `Client.connect`/`send_text`/`recv`)
lives in `lib/infrastructure/websocket/` and is reused by live brokers.

### Synthetic

A fake broker adapter at `lib/infrastructure/acl/synthetic/` — used
whenever you start the server without a real broker. Implements
`Broker.S` by running a deterministic random walk
(`Generator.generate`) and wobbling the trailing bar on each `bars`
call so the polling stream emits visible intrabar updates.

    let syn = Synthetic.Synthetic_broker.make () in
    let client = Synthetic.Synthetic_broker.as_broker syn in
    (* identical call site to Finam / BCS: *)
    let bars = Broker.bars client ~n:500
      ~instrument:(Instrument.of_qualified "SBER@MISX")
      ~timeframe:Timeframe.H1 in

It's symmetric to the live adapters by design: there is no
special-cased "synthetic mode" in the HTTP server or the stream
registry, so real-broker errors aren't silently masked by fallback
data, and strategies / backtests run against a stable source no
matter which broker the server was started with. Venue list is a
single placeholder (`MISX`) so the UI dropdown still renders.

### Finam

Auth: long-lived portal *secret* → short-lived JWT via `/v1/sessions`,
refreshed transparently by `Finam.Auth`.

Instrument routing: `TICKER@MIC` (e.g. `SBER@MISX`). Board is accepted
on `Instrument.t` but ignored by Finam — their REST picks the primary
board server-side and echoes it back in `/v1/assets` responses.

    let cfg = Finam.Config.make ~secret ?account_id () in
    let client = Finam.Rest.make ~transport ~cfg in
    let sber = Instrument.make
      ~ticker:(Ticker.of_string "SBER")
      ~venue:(Mic.of_string "MISX") () in
    let bars = Finam.Rest.bars client ~instrument:sber ~timeframe:Timeframe.H1 in

WebSocket (`lib/infrastructure/acl/finam/ws.ml` + `ws_bridge.ml`)
follows the asyncapi-v1.0.0 envelope — `{action, type, data, token}` —
with one multiplexed socket covering all subscriptions. JWT refreshes
on every outbound message via `Auth.current`.

Docs:
- REST: <https://tradeapi.finam.ru/docs/rest>
- gRPC: <https://tradeapi.finam.ru/docs-new/grpc-new>
- WebSocket: <https://tradeapi.finam.ru/docs-new/async-api-new/>
- Protos: <https://github.com/FinamWeb/finam-trade-api>

### BCS

Auth: OAuth2 `refresh_token` → short-lived access_token via Keycloak
realm `tradeapi` at `be.broker.ru`. The refresh_token is issued in
«БКС Мир инвестиций» → «О счёте» → «Токены API»; `Bcs.Auth` caches
the access_token and re-exchanges on expiry.

Instrument routing: `(classCode, ticker)` pair. `Instrument.board`
maps 1:1 to `classCode` (`TQBR`, `SMAL`, `SPBFUT`, …); when absent,
the adapter substitutes `Config.default_class_code` (`TQBR` by
default). `Instrument.venue` is ignored — BCS-via-QUIK is MOEX-only
in our config.

    let cfg = Bcs.Config.make ~refresh_token ?account_id () in
    let client = Bcs.Rest.make ~transport ~cfg in
    let sber = Instrument.make
      ~ticker:(Ticker.of_string "SBER")
      ~venue:(Mic.of_string "MISX")
      ~board:(Board.of_string "TQBR") () in
    let bars = Bcs.Rest.bars client ~instrument:sber ~timeframe:Timeframe.H1 in

WebSocket (`lib/infrastructure/acl/bcs/ws.ml` + `ws_bridge.ml`) uses
a **per-subscription** socket: each `(classCode, ticker, timeFrame)`
opens its own WS at `wss://ws.broker.ru/trade-api-market-data-connector/api/v1/last-candle/ws`
and tears down on unsubscribe. JWT goes into the `Authorization`
handshake header.

Docs:
- Portal: <https://trade-api.bcs.ru/>
- Reference Go client (protocol source of truth):
  <https://github.com/tigusigalpa/bcs-trade-go>

## Paper-trading mode

`lib/infrastructure/paper/paper_broker.ml` is a decorator that wraps
any `Broker.client`, intercepts order operations, and simulates fills
against an in-memory book. Market data (`bars`, `venues`) still
delegates to the wrapped source — live Finam, BCS, or Synthetic — so
charts and strategies see the same prices they would in production,
but no order ever leaves the process.

Use it to smoke-test a strategy on a real data feed before routing
orders to a broker:

    dune exec -- bin/main.exe serve --broker finam --paper \
        --secret "$FINAM_SECRET" --account "$FINAM_ACCOUNT_ID"

`--paper` composes with every `--broker` choice: `synthetic` is fine
for offline simulation, `finam` / `bcs` for a live-data dress
rehearsal.

### Fill model

Paper follows the same **next-bar execution** rule as the backtester
(`lib/domain/engine/backtest.ml`), so a strategy's P&L in paper and in
backtest match on identical signal streams:

| Kind        | Fill trigger                                      | Fill price                |
| ----------- | ------------------------------------------------- | ------------------------- |
| Market      | first bar strictly after placement                | `open` of that bar        |
| Limit buy   | next bar whose `open ≤ limit` or `low ≤ limit`    | `min(open, limit)` — gap favours the trader |
| Limit sell  | next bar whose `open ≥ limit` or `high ≥ limit`   | `max(open, limit)`        |
| Stop buy    | next bar whose `open ≥ stop` or `high ≥ stop`     | `max(open, stop)`         |
| Stop sell   | next bar whose `open ≤ stop` or `low ≤ stop`      | `min(open, stop)`         |
| Stop-limit  | not simulated in this release — stays `New`       | —                         |

An order placed "during" bar T cannot fill at bar T itself; it can
only fill at bar T+1's open or later. This is the rule that keeps
paper fills free of same-bar lookahead.

### How the decorator learns about new bars

Paper is passive by design — callers feed bars via `on_bar`. The wiring
in `bin/main.ml` plugs two sources into the decorator:

1. The live WebSocket path: whenever `Finam.Ws_bridge` or
   `Bcs.Ws_bridge` delivers a candle, `bin/main.ml` calls
   `Paper.on_bar` in addition to `Stream.push_from_upstream`.
2. The polling path: `Paper.bars` sinks the trailing candle it
   returns, so synthetic-source deployments (no WS) still advance as
   the UI polls `/api/candles`.

Tests drive `on_bar` directly — unit tests in
`test/unit/infrastructure/paper/paper_broker_test.ml` cover market
fill at next open, same-bar non-fill, limit fill with and without gap,
stop trigger, cancel-before-fill, and cross-instrument isolation.

### What paper does not do (yet)

- No partial fills — orders go straight from `New` to `Filled`.
- No fees or slippage modelling.
- No position / cash accounting on the decorator itself (the
  backtester's `Portfolio` is the reference for that; a live engine
  running on top of paper can wrap the same structure).
- Stop-limit orders are accepted but never transition past `New`.

These are natural follow-ups once a live strategy engine is in place;
the decorator's surface area is intentionally small so those additions
land without breaking the current API.
