# Architecture overview

## The whole system in one picture

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

- **Sources and effects differ** between Backtest and Live;
  the pure core is the **same code** in both.
- **Domain** (`Stream`, `Step`, `Pipeline`, `Backtest`,
  `Strategy`) knows nothing about Eio or brokers.
- **Infrastructure** (`Eio_stream`, Finam/BCS/Paper adapters)
  implements sources and effects.
- **Application** (`Live_engine`) is a thin wrapper tying a
  source to the pipeline to an effect.

## Layering

The project follows **hexagonal architecture** (ports & adapters):
pure domain logic in the center, orchestration around it,
infrastructure at the edges. Directory layout mirrors the layers:

```
lib/
  domain/              ← pure, no IO, no external deps beyond core
    core/              ← Instrument, Candle, Order, Signal, Decimal
    indicators/        ← SMA, EMA, RSI, MACD, …
    strategies/        ← SMA_Crossover, RSI_MeanReversion, …
    engine/            ← Portfolio, Risk, Step, Pipeline, Backtest
    stream/            ← functional streams on Seq.t
    ml/                ← logistic regression (offline training)

  application/         ← orchestrates the domain via ports
    broker/            ← Broker.S port + existential Broker.client
    live_engine/       ← streams bars → pipeline → broker orders

  infrastructure/      ← adapters implementing ports, touching IO
    acl/               ← external broker translators
      finam/
      bcs/
      synthetic/
    paper/             ← Paper_broker decorator (simulated fills)
    inbound/http/      ← HTTP API + SSE stream registry
    websocket/         ← shared WS primitives (frame codec, Resilient)
    eio_stream/        ← Eio.Stream → Stream.t adapter
    http_transport/    ← cohttp-eio wrapper
    log/               ← wrapper over Logs library
```

## The dependency rule

Arrows point inward — **nothing in `domain/` imports from
`application/` or `infrastructure/`**. This is the anti-corruption
rule that keeps domain pure and testable. The compiler enforces it
through `dune` library dependencies and `.mli` files; see
[ADR 0002: .mli guardrails](../adr/0002-mli-guardrails.md).

```
domain           ◀───── application ◀───── infrastructure
  (pure)                (orchestrates)           (IO, ports)

no external deps     imports domain           imports both
no IO                 depends on ports         implements ports
```

## The core abstraction: Broker.S

Everything the system needs from an external broker is captured in
a single OCaml module type:

```ocaml
(* lib/application/broker/broker.ml *)
module type S = sig
  type t
  val name : string
  val bars      : t -> n:int -> instrument:Instrument.t ->
                  timeframe:Timeframe.t -> Candle.t list
  val venues    : t -> Mic.t list
  val place_order : t -> instrument:Instrument.t -> side:Side.t ->
                    quantity:Decimal.t -> kind:Order.kind ->
                    tif:Order.time_in_force ->
                    client_order_id:string -> Order.t
  val get_orders  : t -> Order.t list
  val get_order   : t -> client_order_id:string -> Order.t
  val cancel_order: t -> client_order_id:string -> Order.t
end

type client = E : (module S with type t = 't) * 't -> client
```

An existential wrapper `Broker.client` hides the concrete adapter
from callers. Finam, BCS, Synthetic and Paper all implement this
same port. Adding a new broker means writing one `.ml` file that
satisfies `S` — no other change is needed upstream.

## Data flow: bar → order

```
                                     ┌─────────────────┐
 WS upstream (Finam/BCS/Synthetic)   │ HTTP /api/stream│
              ▼                       │      (SSE)      │
     ┌────────────────┐               └────────▲────────┘
     │  Stream        │◀── fan-out ──┐         │
     │  registry      │               │        │
     └────────────────┘               │        │
              │                       │        │
              ▼                       ▼        │
       Eio.Stream ──────► Live_engine.run fiber
       (of candles)       │
                          ▼
       Stream.of_eio ──► Pipeline.run (Step) ──► Broker.place_order
           (pull)          (pure transducer)            │
                                                        ▼
                                                  Paper / Finam / BCS
                                                        │
                                                   fill event
                                                        │
                                                        ▼
                                       Live_engine.on_fill_event
                                                        │
                                                        ▼
                                             Portfolio.commit_fill
```

A single candle arriving from the WS bridge flows through an
`Eio.Stream`, crosses into the pure domain via
[`Eio_stream.of_eio_stream`](../../lib/infrastructure/eio_stream/),
drives the shared state machine
([`Engine.Pipeline`](state-machine.md)), emits an *intent event*
that the engine translates to a broker order, and eventually
returns as a *fill event* that updates the
[reservation ledger](reservations.md).

The same `Pipeline.run` function is driven by `Backtest.run` over
a historical `Candle.t list` — so paper and backtest P&L agree
bit-for-bit on identical inputs. See
[`testing.md`](testing.md) for the differential test that
enforces this invariant.

## Layering discipline in `dune`

Each layer is a separate library with an explicit `libraries`
clause; the compiler rejects upward imports:

```
lib/domain/engine/dune:
  (libraries core indicators strategies stream)

lib/application/live_engine/dune:
  (libraries core broker strategies engine log stream eio_stream eio)

lib/infrastructure/paper/dune:
  (libraries core broker engine)
```

Domain has no `eio` dependency and no broker-specific code. If
someone tried to `open Eio` inside `lib/domain/engine/step.ml` the
build would fail.

## See also

- [Domain model](domain-model.md) — the types that flow through
  the system.
- [State machine](state-machine.md) — how bars become intents.
- [Reservations](reservations.md) — how intents become ledger
  entries.
- [Live engine](live-engine.md) — the orchestration layer.
- [Hexagonal ADR](../adr/0001-hexagonal-architecture.md) — why
  this layering over alternatives.
