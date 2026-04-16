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
    dune exec -- bin/main.exe serve --port 8080

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

## Finam connector

REST client (`lib/finam/rest.ml`) is built around a pluggable
`Transport.t` — pure and testable with an in-memory fake; wire cohttp-eio
in production. Set your token and account via:

    let cfg = Finam.Config.make ~access_token ~account_id () in
    let client = Finam.Rest.make ~transport ~cfg in
    let sber = Instrument.make
      ~ticker:(Ticker.of_string "SBER")
      ~venue:(Mic.of_string "MISX") () in
    let bars = Finam.Rest.bars client ~instrument:sber ~timeframe:Timeframe.H1 in
    ...

WebSocket (`lib/finam/ws.ml`) defines the async-api subscription protocol
and event decoder as pure values; glue to `ocaml-websocket`, `h2`, or a
home-grown Eio frame reader.

gRPC protos for Finam Trade:
<https://github.com/FinamWeb/finam-trade-api>

docs:
- REST: <https://tradeapi.finam.ru/docs/rest>
- gRPC: <https://tradeapi.finam.ru/docs-new/grpc-new>
- WebSocket: <https://tradeapi.finam.ru/docs-new/async-api-new/>
