# 0004. One `Pipeline.run` for Backtest and Live

**Status**: Accepted
**Date**: 2026-04-17

## Context

The backtester (`Backtest.run` over a candle list) and the live
engine (`Live_engine.on_bar` per WebSocket event) were two
parallel implementations of the same conceptual algorithm:

```
for each bar c:
  execute pending signal at c.open_ (sizing → Risk.check → Portfolio.fill)
  mark-to-market at c.close
  feed c to strategy, queue any non-Hold signal for next bar
```

They drifted. A code review spotted that `Risk.check` was called
in `Backtest` but not in `Live_engine`. Equity calculations for
sizing used different formulas
(`Portfolio.equity portfolio mark` vs.
`initial_cash + position * price`). The sizing `strength` clamp
was `Float.max 0.1 strength` in one but not the other.

None of the existing unit tests caught this, because the tests
lived with each driver and asserted its behavior in isolation.
Drift between them was undetectable without a *comparative* test.

## Decision

Extract the shared logic into a single module,
`lib/domain/engine/step.ml`, with primitives:

- `execute_pending config state c → state * (signal * settled) option`
- `advance_strategy config state c → state`

Build a `lib/domain/engine/pipeline.ml` that composes them into
a stream transducer:

```ocaml
val run : Step.config -> Step.state -> Candle.t Stream.t -> event Stream.t
```

Make `Backtest.run` and `Live_engine.run` thin **drivers** over
this single `Pipeline.run`:

```ocaml
(* Backtest: finite source, aggregate consumer *)
candles
|> Stream.of_list
|> Pipeline.run step_cfg state0
|> Stream.to_list
|> aggregate

(* Live: Eio source, side-effect consumer *)
Eio_stream.of_eio_stream source
|> Pipeline.run t.step_cfg t.state
|> Stream.iter (apply_event t)
```

Guard the invariant with a **differential test**: same strategy
+ same candle series → identical fills and identical final
portfolio across both drivers.

## Alternatives considered

### Keep parallel implementations, add tests to each

The previous state. Tests would live with each driver and assert
its own behavior. This is what we had when the drift happened —
unit tests can't catch "Backtest and Live disagree" without an
explicit cross-check.

### Share only the sizing / risk helpers, leave driving code
separate

Extract `size_for_signal` and `check_and_apply` as functions,
call them from both drivers. Reduces but doesn't eliminate
drift: the *order* of operations (execute pending, mark,
advance) is still independently implemented. Easy to get the
sequencing subtly different.

### Use a framework (effects, monadic interpretation)

A `trading_effect` algebraic effect or a free monad could let
Backtest and Live implement different handlers for the same
program. Works, but pulls in more machinery than warranted for
one shared state machine. We're not at the "multiple orthogonal
effects" scale yet.

### Unified driver, parameterized over source type

A single `run : config → state → Candle.t <something> → result
stream` where `<something>` is a type abstract enough to
represent both a list and an Eio stream. `Stream.t` (our
`Seq.t` alias) already does this — no extra type parameter
needed. See [ADR 0003](0003-stream-over-frp.md).

## Consequences

**Easier**:

- Divergence is structurally impossible without breaking the
  compile. Fixing sizing in `Step.execute_pending` affects both
  drivers atomically.
- The differential test went from "load-bearing regression
  catcher" to "guard on the wrappers" — the pipeline itself is
  identical by construction, so the test now catches drift in
  how drivers consume the event stream, not in the state machine
  itself.
- Live engine got `Risk.check` for free when we integrated. The
  previous "dyre live engine didn't check max_leverage" hole
  closed as a side effect.

**Harder**:

- Single `Step.config` record for both drivers requires some
  care: `auto_commit` flag distinguishes Backtest (always
  commit) from Live (defer to broker event). More on this in
  [reservations ADR](0005-reservations-ledger.md).
- Changes to `Step` affect everything. Before refactoring, the
  differential test must be running and green.

**To watch for**:

- Temptation to add driver-specific shortcuts. Don't. If Live
  needs something Backtest doesn't, either push it up to the
  driver (e.g., broker I/O), or add a flag to `Step.config` that
  Backtest sets to a trivial value.
- The shared state machine doesn't know about partial fills or
  slippage — those are broker-side, modeled in Paper (a
  decorator) or real adapters. Step only reserves; someone else
  commits. This separation is what keeps Backtest and Live's
  state machine identical despite broker heterogeneity.

## References

- [State machine doc](../architecture/state-machine.md).
- [Streams doc](../architecture/streams.md).
- [Testing doc](../architecture/testing.md) — differential test
  rationale.
- [ADR 0005: reservations ledger](0005-reservations-ledger.md)
  — how the `auto_commit` flag lets Live defer.
