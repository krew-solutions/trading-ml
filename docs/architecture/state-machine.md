# State machine: Step and Pipeline

`Backtest` (historical replay) and `Live_engine` (real-time
trading) are two **drivers** of one **shared state machine**.
This is enforced by construction — both call the same
`Engine.Pipeline.run` function — so divergence between
backtest P&L and live-trading P&L on identical inputs is
impossible without breaking compilation.

## Step: atomic transitions

`lib/domain/engine/step.ml` holds the primitives that every tick
relies on. Two functions, one state record:

```ocaml
type state = private {
  strat : Strategies.Strategy.t;
  portfolio : Portfolio.t;
  pending_signal : Signal.t option;
  last_bar_ts : int64;
  reservation_seq : int;
}

val execute_pending :
  config -> state -> Candle.t -> state * (Signal.t * settled) option

val advance_strategy :
  config -> state -> Candle.t -> state
```

- `execute_pending` fires any signal queued on the previous bar
  at `c.open_`. Sizes via `Risk.size_from_strength`, gates
  through `Risk.check` against
  [`Portfolio.available_cash`](reservations.md),
  [reserves](reservations.md) the cash/qty, optionally commits
  immediately (Backtest) or defers to the broker (Live).
- `advance_strategy` feeds `c` to the strategy and queues any
  non-`Hold` signal for the next bar.

These separate because `Backtest` needs to mark-to-market at
`c.close` *between* the two steps for its equity curve.

### `auto_commit` flag

```ocaml
type config = {
  limits : Risk.limits;
  instrument : Instrument.t;
  fee_rate : float;
  auto_commit : bool;
}
```

- `auto_commit = true` (Backtest): `execute_pending` reserves and
  commits in one step. Behaves like a direct `Portfolio.fill`.
  No broker latency to simulate.
- `auto_commit = false` (Live): `execute_pending` reserves only;
  `Portfolio.reservations` grows. Commit happens later when a
  broker fill event arrives via `Live_engine.on_fill_event`.

This flag is the single point where the two modes diverge. Every
other piece of logic — sizing, Risk, fee calculation,
portfolio ops — is shared.

## Pipeline: the shared transducer

`lib/domain/engine/pipeline.ml`:

```ocaml
type event = {
  bar : Candle.t;
  state : Step.state;
  settled : (Signal.t * Step.settled) option;
}

val run : Step.config -> Step.state -> Candle.t Stream.t -> event Stream.t
```

Implementation (stripped of comments):

```ocaml
let run cfg state0 =
  Stream.scan_filter_map state0 (fun state c ->
    if Int64.compare c.ts state.last_bar_ts <= 0 then state, None
    else
      let state1, fill_opt = Step.execute_pending cfg state c in
      let state2 = Step.advance_strategy cfg state1 c in
      state2, Some { bar = c; state = state2; settled = fill_opt })
```

Read bottom to top: for each candle `c` whose timestamp is
strictly newer than the last one seen, thread `state` through
`execute_pending` then `advance_strategy`, emit an `event`. A
signature that fits on one line of paper captures the entire
bar-processing logic of the system.

## Driver 1: Backtest

`lib/domain/engine/backtest.ml` consumes the event stream into a
summary:

```ocaml
let events =
  candles
  |> Stream.of_list
  |> Pipeline.run step_cfg state0
  |> Stream.to_list
in
let fills = List.filter_map fill_of_event events in
let equity_curve = List.map mark_to_close events in
let final_portfolio = (last events).state.portfolio in
{ final; fills; equity_curve; max_drawdown; total_return; num_trades }
```

Materialize the event list, aggregate. `Stream.of_list` makes the
historical candle list look like any other stream.

## Driver 2: Live_engine

`lib/application/live_engine/live_engine.ml` consumes the same
event stream but with side effects:

```ocaml
let run t ~source =
  Eio_stream.of_eio_stream source
  |> Engine.Pipeline.run t.step_cfg t.state
  |> Stream.iter (fun event ->
    with_lock t (fun () -> apply_event t event))
```

`apply_event` updates a mutable snapshot for external queries
(position, portfolio), then submits the settled trade to the
broker (which will fire back a fill event — see
[live engine](live-engine.md)).

## Symmetry property

```
candles ─► Pipeline.run ─► events ─► list ─► summary   (Backtest)
                                 └──► iter ─► effects  (Live)
```

Both paths execute identical `Pipeline.run` with identical
`Step.config` (modulo `auto_commit`). The `event.state` at any
point carries the full portfolio + strategy + pending signal,
so consumers pick whatever slice they need without redoing the
work.

The [differential test](testing.md#differential) asserts this:
run `Backtest` and `Live_engine + Paper` over the same candle
series, verify that fills match bar-by-bar and final portfolios
agree to six decimal places.

## Why not one giant recursive loop?

Earlier iterations had two parallel implementations — a
`Backtest.run` recursion and a `Live_engine.on_bar` mutable
method. They inevitably drifted: `Risk.check` was added to
Backtest but forgotten in Live, equity calculations used
different formulas. The differential test found the drift only
after it'd been there for months.

Extracting the common step eliminated the drift by construction.
This is [ADR 0004](../adr/0004-pipeline-unification.md).

## See also

- [Streams](streams.md) — the combinators Pipeline uses.
- [Reservations](reservations.md) — what `Step.execute_pending`
  does inside the portfolio.
- [Live engine](live-engine.md) — the side-effecting driver.
- [Testing](testing.md) — differential and unit test coverage.
