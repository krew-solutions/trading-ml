# Testing strategy

The repository has 238 OCaml unit tests and 89 UI (Vitest) tests
that run on every push. The layout separates **unit** tests (fast,
no IO, mirror `lib/`) from **integration-shaped** suites that cut
across modules — the rationale is captured below.

## Directory layout

```
test/
  unit/                    ← per-module, mirrors lib/
    domain/
      core/
      engine/
      strategies/
      ml/
      stream/
    application/
      live_engine/
    infrastructure/
      acl/finam/
      acl/bcs/
      paper/
      websocket/
      eio_stream/
      inbound/http/
  component/               ← cuts across modules (single file now)
  contract/                ← placeholder for protocol tests
  e2e/                     ← placeholder for full-stack tests
  live_smoke/              ← placeholder for live broker smoke runs
```

`dune`'s `include_subdirs unqualified` flattens subdirectories
into a single module namespace per test runner, so filenames must
be globally unique within a runner — vendor-specific tests carry
a broker prefix (`finam_order_test.ml`, `bcs_rest_test.ml`).

## Alcotest setup

Each `test/unit/` subdirectory holds plain `.ml` files that export
a `tests : (string * speed * (unit -> unit)) list` value.
`test/unit/unit_runner.ml` collects them all into one
`Alcotest.run`.

```ocaml
let tests = [
  "name of case", `Quick, (fun () ->
    ... setup ...
    Alcotest.(check int) "description" expected actual);
  ...
]
```

Run with `dune runtest` (all suites) or
`dune runtest test/unit` (just unit).

## Differential test

`test/unit/application/live_engine/differential_test.ml` is the
load-bearing invariant test for the shared state machine: given
the same strategy and candle series, `Engine.Backtest.run` and
`Live_engine + Paper` must produce bit-identical fills and
portfolios.

```ocaml
let test_fills_match () =
  let candles = sine_candles 200 in
  let r = run_backtest candles in
  let _eng, paper = run_live candles in
  Alcotest.(check int) "count" (List.length r.fills)
    (List.length (Paper.fills paper));
  List.iter2 (fun bt p ->
    (* side, qty, price, fee match *)
    ...) r.fills (Paper.fills paper)

let test_portfolios_match () =
  (* final cash, realized_pnl match across all three:
     Backtest.final, Live_engine.portfolio, Paper.portfolio *)
  ...
```

After the pipeline unification ([ADR 0004][adr-0004]) the test
can only fail if:
- Backtest and Live drivers diverge on how they consume the
  event stream,
- Paper's fill simulation desynchronizes from Pipeline's
  reservation reasoning,
- a refactor accidentally changes one code path and not the
  other.

[adr-0004]: ../adr/0004-pipeline-unification.md

Keep this test green. If it fails and the fix is "just update the
expected values", stop — something architecturally significant
has drifted.

## Unit tests per concern

### Domain primitives (`test/unit/domain/core/`)

Decimal arithmetic, Candle invariants, Instrument parsing and
routing. Gospel-specified — `gospel check lib/domain/core/*.mli`
verifies preconditions on decimal division, candle construction
invariants, etc.

### Indicator tests (`test/unit/domain/indicators/`)

One file per indicator. Covers: correctness at known inputs
(e.g. SMA of `[1;2;3;4;5]` with window 3 → `[_;_;2;3;4]`),
numerical stability under long series, edge cases (empty input,
window > length).

### Strategy tests (`test/unit/domain/strategies/`)

Same per-strategy organization. Check crossover points, signal
timing, state evolution. Plus `composite_test.ml` for the voting
policies (Unanimous / Majority / Any / Adaptive / Learned).

### ML tests (`test/unit/domain/ml/`)

Logistic regression — four files split by concern:
`logistic_test.ml` for the math (sigmoid, SGD step, convergence),
`features_test.ml` for feature vector construction,
`trainer_test.ml` for walk-forward training, and
`learned_policy_test.ml` for the composite strategy integration.

### Stream + Eio adapter tests

11 stream tests verify laziness, transducer semantics, edge
cases. 4 Eio adapter tests verify ordering preservation and
crucially — the consumer genuinely suspends on `Eio.Stream.take`
rather than busy-waiting (proved by multi-fiber push-after-yield
timing).

### Portfolio and reservations

12 tests covering fill math, realized PnL on closes and flips,
reserve/commit/release, available_cash/qty accounting, partial
fills, error cases.

### Live engine

11 tests: signal translation, pending-signal semantics,
out-of-order bar rejection, reconcile state transitions,
auto-reconcile triggering, partial-fill roundtrip via Paper.

### ACL tests

Per-broker DTO parsing, wire format encoding, WS frame codec,
authentication flow. Each broker has its own prefixed directory
(`finam/`, `bcs/`); shared primitives (WS RFC 6455 frame) tested
in `websocket/`.

## UI tests

`ui/` runs Vitest 4 with jsdom:

```
npm test        # 89 tests
```

Structure mirrors `src/app/`:

- `indicators/<name>.spec.ts` — math + overlay glue per
  indicator.
- `api.service.spec.ts` — HTTP surface via
  `HttpTestingController`.
- `app.component.spec.ts` — signal-driven reactivity (catalog
  seeding, toggles, candle reloading on symbol change, backtest
  result storage).
- `orders.component.spec.ts` — not yet written; the orders panel
  is wired through `api.service.spec.ts` tests for its HTTP
  surface.
- `test-setup.ts` polyfills `matchMedia` / `ResizeObserver` for
  jsdom.

`ChartComponent` is replaced with a stub in
`app.component.spec.ts` so `lightweight-charts` never touches
jsdom's missing canvas.

## Contract / E2E / component / live smoke

Empty placeholder suites today. The intent:

- **contract**: protocol-level tests between the OCaml HTTP
  backend and the Angular consumer. A frozen snapshot of request
  and response shapes.
- **e2e**: full-stack Playwright-style tests that launch the
  backend, drive the UI, assert behavior.
- **component**: integrated tests that cross module boundaries
  but don't need the full stack (currently has one WS echo test).
- **live_smoke**: tests that require real broker credentials and
  live market hours. Skipped in CI; run manually before a
  production deploy.

## Running tests

```bash
# All OCaml suites
dune runtest

# Just unit
dune runtest test/unit

# Specific test file (forces re-run)
dune runtest test/unit --force

# UI tests
cd ui && npm test
```

Tests typically complete in under a second per suite. The
component `ws echo` test is the slowest at ~2ms because it
actually spawns an Eio server.

## Conventions

- **Alcotest**: use `` `Quick `` for all tests — we don't have
  anything that would benefit from `` `Slow `` gating today.
- **Test names**: lowercase, space-separated, descriptive of the
  property being verified. E.g. `"scan_map is lazy"` is better
  than `"test_scan_map_lazy"`.
- **Tolerances**: use `Alcotest.float 1e-6` for decimal
  comparisons where the fixed-point rounding might intrude;
  exact `Decimal.equal` only when you can reason about the rounding
  explicitly.
- **Mocks**: prefer minimal module-literal mocks over
  hand-rolled class hierarchies. See `Recording_broker`,
  `Reporting_broker`, `mk_stub_source` in live_engine tests for
  the pattern.
