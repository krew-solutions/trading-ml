# 0003. Custom streams on `Seq.t` over FRP libraries

**Status**: Accepted
**Date**: 2026-04-17

## Context

The trading pipeline processes a sequence of bars through
stateful transformations (strategy, risk gate, portfolio update)
and emits orders. The backtester drives this over a historical
list; the live engine drives it over a WebSocket-sourced stream.

We needed a **value-oriented dataflow primitive** that:

1. Runs over both finite lists (Backtest) and unbounded live
   streams (Live).
2. Threads state through the transformation without mutable
   globals.
3. Is fully functional — composition of pure operators.
4. Integrates with OCaml 5 + Eio concurrency at a single,
   auditable boundary.

The first draft of the live engine used ad-hoc mutable state in
a callback-driven class; Backtest used an explicit recursive
`loop` with accumulators. They duplicated the sizing and risk
logic. After we extracted the shared step
([ADR 0004](0004-pipeline-unification.md)), we needed the
stream abstraction both drivers could consume.

## Decision

**Write a minimal stream library on top of `Stdlib.Seq.t`**, with
an `Eio.Stream.t → Seq.t` adapter in a separate module.
Don't adopt an FRP/dataflow library.

`lib/domain/stream/stream.ml` is ~25 lines of actual code,
mostly re-exports of `Seq` functions plus two missing
primitives: `scan_map` (Mealy transducer — thread state, emit
one output per input) and `scan_filter_map` (same with optional
emit).

`lib/infrastructure/eio_stream/eio_stream.ml` is 6 lines: a
recursive `go ()` that returns `Seq.Cons (Eio.Stream.take s, go)`,
crossing the push/pull boundary at exactly one function.

## Alternatives considered

### `dbuenzli/react`

Classic OCaml FRP. Event + signal combinators. Mature,
well-designed. API is **frozen** by the author's explicit
statement. Push-based: every `Var.set` propagates synchronously
to all observers.

Downsides:

- Push-based conflicts with our pull orientation. `Eio.Stream`
  is already push-based upstream; we want to invert into
  pull-based downstream so composition reads top-to-bottom like
  Unix pipes.
- No Eio bridge. `lwt_react` exists; no `eio_react`.
- `S.switch` / dynamic signal graphs — we don't need it. Our
  graph is linear.

### `rxocaml`

Direct port of ReactiveX. Last commit 2019, not on opam,
OCaml 5 untested. Non-starter.

### Jane Street's `incremental`

Self-adjusting computation with dependency DAG, cutoff, and
dynamic graph via `bind`. Well-designed for widescale derived
values — their risk calculation use case. API is imperative at
the orchestration layer (`Var.set`, `stabilize`,
`Observer.value`).

Downsides:

- Overkill for a linear pipeline. Their sweet spot is DAG with
  high fan-out and sparse input changes; ours is
  `bars → signals → orders` with one fan-in (`Portfolio` +
  `Signal`).
- ~30ns per node overhead in their own benchmarks (for computations
  smaller than that).
- Imperative orchestration conflicts with the functional
  paradigm we're pursuing.

### Bünzli's `note` (successor to `react`)

Author marks it "*potential* successor", version series 0.0.x,
zero opam dependents. Pre-1.0, explicitly experimental. No.

### Plain recursive `loop` without a stream abstraction

What Backtest had originally. Works for the finite case, scales
to the infinite case via manual stepping. But the abstraction
"stream-of-things you can `map`, `filter`, `scan_map`, `iter`
on" is load-bearing for reading the code top-to-bottom — the
pipeline becomes a composition of operators instead of a
hand-rolled state machine.

## Consequences

**Easier**:

- Backtest and Live read almost identically:
  `src |> Pipeline.run step_cfg state0 |> consume`. The source
  and the consumer vary; the middle is shared.
- Testing: stream combinators tested in isolation with
  `Stream.of_list` + assertions on `Stream.to_list`. No Eio,
  no real streams, no mocking framework.
- Zero external dependencies for the domain stream module.
  `Seq.t` is in stdlib since OCaml 4.07.

**Harder**:

- OCaml's `Seq` is minimal — we had to write `scan_map` / 
  `scan_filter_map` ourselves. Six lines each, but still a
  decision surface. If stdlib adds these later, we'd migrate.
- No cutoff (no-op recomputation elimination). Doesn't matter
  for our shape: each candle triggers work proportional to the
  candle, not a sweep over all derived state.
- No backpressure signaling beyond what `Eio.Stream` provides.
  If the engine can't keep up, the `Eio.Stream` buffer fills up
  and producers block. Acceptable; if we ever drop bars we'd
  want explicit buffering + overflow policies.

**To watch for**:

- If the pipeline ever grows a real DAG (e.g., one shared
  indicator feeding several strategies that feed a portfolio
  aggregator), the linear stream model starts to look forced.
  At that point revisit Incremental.
- `Seq.t` isn't thread-safe — each forced node calls the
  underlying function. Our single-consumer model sidesteps this,
  but multi-consumer from a single Eio.Stream would need a tee
  primitive we don't have.

## References

- Yaron Minsky, ["Introducing
  Incremental"](https://blog.janestreet.com/introducing-incremental/),
  Jane Street blog, 2015.
- [`dbuenzli/react`](https://github.com/dbuenzli/react) and
  [`dbuenzli/note`](https://github.com/dbuenzli/note).
- [Streams doc](../architecture/streams.md).
