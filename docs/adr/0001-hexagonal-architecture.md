# 0001. Hexagonal architecture

**Status**: Accepted
**Date**: 2026-04-15

## Context

The system has to integrate with multiple external brokers
(Finam, BCS, eventually more) and present their data through a
single UI. Each broker has different wire formats, authentication
flows, WebSocket protocols, and order semantics. Without a
deliberate boundary, broker-specific detail leaks into the
strategy, UI, and test code — every consumer of a broker's data
becomes coupled to the broker's wire format.

Early iterations had `Symbol.t = string` passed from the
`/api/candles` query directly into a Finam-specific adapter.
Adding BCS required changing the type (`(classCode, ticker)`),
which rippled into every strategy, test, and JSON encoder.

## Decision

Adopt **hexagonal architecture** (Alistair Cockburn, aka
"ports and adapters"):

- **Domain layer** (`lib/domain/`) has zero external dependencies
  beyond `core`. No IO, no networking, no broker knowledge.
- **Application layer** (`lib/application/`) defines **ports**
  (abstract module signatures) for what the domain needs from the
  outside, and orchestrates the domain through those ports.
- **Infrastructure layer** (`lib/infrastructure/`) provides
  **adapters**: concrete implementations of the ports. Each
  broker integration is one adapter.

The compiler enforces the dependency direction through `dune`
library declarations. A domain file that tried to
`open Eio` or `open Cohttp_eio` would fail to build.

The central port is `Broker.S`:

```ocaml
module type S = sig
  type t
  val name : string
  val bars : t -> n:int -> instrument -> timeframe -> Candle.t list
  val venues : t -> Mic.t list
  val place_order : t -> ... -> Order.t
  val get_orders : t -> Order.t list
  val get_order : t -> client_order_id:string -> Order.t
  val cancel_order : t -> client_order_id:string -> Order.t
end
```

One signature, six operations. Every broker adapter implements it.
The rest of the system programs against `Broker.client`
(existentialized `S`) and never names a concrete broker.

## Alternatives considered

### Clean architecture / onion architecture

Similar layering philosophy, different terminology. Clean
architecture draws "use case" layers; onion emphasizes
concentric rings. For our purposes the distinction is mostly
cosmetic — we're expressing the same "dependency rule" (code in
inner layers doesn't import from outer layers).

We picked hexagonal because **ports** map naturally to OCaml
`module type`s, and **adapters** to first-class modules. The
language's features do the enforcement without ceremony.

### Monolithic design (one library per broker, no port)

Each broker could have its own library, and the consumer picks
one at compile time via functor. This works for 1-2 brokers but
forces every consumer (strategies, UI adapter, tests) to be
parameterized over the broker type. The existential `Broker.client`
hides this parameter at runtime, enabling `--broker` CLI flag and
mixed-broker deployments.

### ACL only at the HTTP boundary

Some projects put an anti-corruption layer only between HTTP and
internal code, accepting that internal code is broker-shaped.
This was our starting point, and it leaked — `Ticker.t` didn't
exist, indicators computed on strings, the routing for BCS
needed `classCode` that had no place in the string-based model.
Moving the ACL into the ACL adapters (`lib/infrastructure/acl/*`)
and keeping the domain in pure terms of `Instrument.t` etc.
eliminates this.

See [`reference_hexagonal.md`][hex-memory] in the working
memory for reading notes on Cockburn's original paper and
Stöckl's go-iddd reference implementation.

[hex-memory]: ../../../.claude/projects/-home-ivan-emacsway-apps-trading/memory/reference_hexagonal.md

## Consequences

**Easier**:

- Adding a new broker: one file in
  `lib/infrastructure/acl/<broker>/<broker>_broker.ml`
  implementing `Broker.S`. No change anywhere else.
- Testing: domain logic (strategies, indicators, portfolio,
  state machine) tested with trivial synthetic inputs; no broker
  mock required for pure logic tests.
- Reasoning about data flow: the dependency graph is a DAG with
  explicit layer boundaries, visible in `dune` files.

**Harder**:

- Some duplication at the ACL layer: each broker re-parses JSON,
  re-encodes enums, re-handles auth. This is by design — the
  *abstraction* lives at the port, not in shared ACL code.
- New engineers need to learn the layering. Violations
  (`open Eio` in a domain file) are caught at build time, but the
  concept requires one conversation.

**To watch for**:

- The temptation to put "just one" helper that reaches across
  layers "because it's convenient". Every such helper erodes the
  boundary. Push new responsibilities into the right layer or
  expose a proper port method.
- New ports should be small. A `Broker.S` that grows to 40
  methods is a smell that the port has become "whatever the
  broker can do", not "what the system needs".

## References

- Alistair Cockburn, ["Hexagonal
  architecture"](https://alistair.cockburn.us/hexagonal-architecture/),
  2005.
- Matthias Stöckl, [go-iddd](https://github.com/AntonStoeckl/go-iddd)
  — a Go reference implementation of hexagonal + DDD.
- [Domain model overview](../architecture/domain-model.md).
- [Architecture overview](../architecture/overview.md).
