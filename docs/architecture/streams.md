# Streams

Bars flow through the system as a **lazy, pull-driven sequence**.
The domain never sees push-based event emitters, mutable
observables, or the Eio concurrency primitives that drive live
deployments — all of that is kept at one boundary and the rest is
pure functional pipeline.

## Why not an FRP library

Common alternatives considered:

- **ReactiveX / RxOCaml** — stream-composition in the FRP
  tradition. Push-based by default, stream-of-events oriented.
- **Incremental** (Jane Street) — dataflow DAG optimizer with
  cutoff, well-suited for risk-calculation graphs. Imperative
  orchestration (`Var.set`, `stabilize`, `Observer.value`).
- **`react` / `note`** (Daniel Bünzli) — classic OCaml FRP.
  Push-based signals and events. Stable but frozen API.

Why we rolled our own:

- The trading pipeline is **linear** (`bars → signals → orders`)
  with one or two fan-in points; wide dataflow DAGs are not our
  shape.
- We wanted **pull-based** semantics — the source (historical
  list or `Eio.Stream`) drives the pace, the consumer reacts.
- We wanted **zero external dependencies** for the domain layer;
  `Seq.t` is in stdlib.

See [ADR 0003](../adr/0003-stream-over-frp.md) for the full
reasoning.

## What's in `lib/domain/stream/`

A thin module over `Stdlib.Seq` that re-exports what we use and
adds the one primitive the stdlib is missing:

```ocaml
type 'a t = 'a Seq.t

val of_list : 'a list -> 'a t
val to_list : 'a t -> 'a list
val map : ('a -> 'b) -> 'a t -> 'b t
val filter_map : ('a -> 'b option) -> 'a t -> 'b t
val take : int -> 'a t -> 'a t
val zip : 'a t -> 'b t -> ('a * 'b) t
val fold_left : ('acc -> 'a -> 'acc) -> 'acc -> 'a t -> 'acc
val iter : ('a -> unit) -> 'a t -> unit
val unfold : ('state -> ('a * 'state) option) -> 'state -> 'a t

val scan_map :
  'state -> ('state -> 'a -> 'state * 'b) -> 'a t -> 'b t

val scan_filter_map :
  'state -> ('state -> 'a -> 'state * 'b option) -> 'a t -> 'b t
```

### `Seq.t` primer

```ocaml
type +'a t = unit -> 'a node
and  'a node = Nil | Cons of 'a * 'a t
```

A function that, when invoked, returns either end-of-stream or
head-value + tail-thunk. Everything is computed on demand:
mapping over an infinite sequence doesn't allocate anything
until you start pulling.

### `scan_map`: the missing primitive

`Seq.scan` emits accumulator snapshots; we need a
Mealy-transducer shape — thread state, emit one **distinct**
output per input. Implementation is six lines:

```ocaml
let rec scan_map state step seq () =
  match seq () with
  | Seq.Nil -> Seq.Nil
  | Seq.Cons (x, rest) ->
    let state', y = step state x in
    Seq.Cons (y, scan_map state' step rest)
```

This is the shape `Pipeline.run` uses — `state` threads through,
`event` records come out.

`scan_filter_map` is the same with `'b option` output: state
always advances, but the step may choose not to emit.

## The Eio boundary

`lib/infrastructure/eio_stream/eio_stream.ml` is the **one and
only** place that bridges Eio's push-based concurrency to our
pull-based streams:

```ocaml
let of_eio_stream (s : 'a Eio.Stream.t) : 'a Stream.t =
  let rec go () = Seq.Cons (Eio.Stream.take s, go) in
  go
```

Six lines. Each forced `Cons` suspends the current fiber on
`Eio.Stream.take` until upstream pushes a value. The returned
stream is effectively infinite — callers must bound via
`Stream.take` or consume with `Stream.iter` on a cancellable
fiber.

Above this line (domain code) sees only `Stream.t`. Below
(WS bridges pushing into `Eio.Stream`) knows only Eio. The
boundary has exactly one function; audit is trivial.

## The driver pattern

Both backtest and live use the same pipeline shape, differing
only in source and sink:

```ocaml
(* Backtest: pull from list, reduce to summary *)
candles
|> Stream.of_list
|> Pipeline.run step_cfg state0
|> Stream.to_list
|> aggregate_into_result

(* Live: pull from Eio source, side-effect on broker *)
bar_source
|> Eio_stream.of_eio_stream
|> Pipeline.run step_cfg t.state
|> Stream.iter (submit_and_commit t)
```

Same pipeline. Different bookends.

```
╔═══════════════╗     ╔════════════╗     ╔════════════════╗
║ Sources       ║     ║ Pure core  ║     ║ Effects        ║
╟───────────────╢     ╟────────────╢     ╟────────────────╢
║ list (BT)     ║ ──► ║ Stream     ║ ──► ║ Portfolio acc. ║ (Backtest)
║ Eio.Stream(L) ║ ──► ║ pipeline   ║ ──► ║ Broker.place   ║ (Live)
╚═══════════════╝     ╚════════════╝     ╚════════════════╝
                       scan_map /
                       fold_left /
                       iter
                       over Seq.t
```

## Testing

The stream module is covered by 11 unit tests in
`test/unit/domain/stream/stream_test.ml`:

- `of_list` / `to_list` round-trip.
- `map`, `filter_map`, `fold_left`, `zip`, `take`, `unfold`
  basics.
- `scan_map` produces cumulative sums.
- `scan_map` lazily composes with infinite `unfold`-generated
  streams + `take`.
- `scan_filter_map` advances state even when not emitting
  (regression guard).

Eio adapter tests in
`test/unit/infrastructure/eio_stream/eio_stream_test.ml` verify
ordering preservation, `take` bounding an infinite source, and
crucially — the consumer genuinely blocks on `Eio.Stream.take`
rather than busy-waiting (tested by pushing from another fiber
after `Eio.Fiber.yield`).

## See also

- [State machine](state-machine.md) — how `scan_filter_map`
  drives `Pipeline.run`.
- [Live engine](live-engine.md) — how the Eio adapter plugs WS
  bar feeds into the pipeline.
- [ADR 0003: stream over FRP](../adr/0003-stream-over-frp.md).
