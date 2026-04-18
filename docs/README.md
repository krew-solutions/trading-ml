# Documentation

This directory contains the project's design and architecture
documentation. For installation, quickstart and CLI reference see
the top-level [`README.md`](../README.md).

## Architecture

Long-form essays on how the system is structured and why. Read in
order for a tour; read individually for a specific concern.

1. [Overview](architecture/overview.md) — hexagonal layers,
   module map, data flow from bar to order.
2. [Domain model](architecture/domain-model.md) — core types
   (`Instrument`, `Candle`, `Order`, `Signal`, `Portfolio`) and the
   invariants they carry.
3. [State machine: Step + Pipeline](architecture/state-machine.md)
   — the shared transducer `Backtest` and `Live_engine` both drive.
4. [Streams](architecture/streams.md) — functional pipeline over
   `Seq.t`, with an `Eio.Stream` adapter as the only push/pull
   boundary.
5. [Reservations ledger](architecture/reservations.md) — cash and
   position accounting across the broker-latency gap:
   `reserve → commit_fill` with `available_cash` gating Risk
   checks.
6. [Live engine](architecture/live-engine.md) — how streaming bars
   become orders; Paper wiring; reconciliation with the broker.
7. [Testing strategy](architecture/testing.md) — unit, component,
   differential; mirroring `lib/` in `test/unit/`.

## Decision records (ADR)

Short, dated notes capturing architecture decisions and their
rationale. See [`adr/README.md`](adr/README.md) for the template
and chronological index.

## Module reference

Auto-generated API documentation (from `.mli` files via `odoc`)
lives at `dune build @doc` output, typically published to GitHub
Pages. This repository uses `.mli` files as the primary guardrail
against leaking implementation details — every domain module has
one.

## Conventions

- **Code examples** are copied from the repo at the time of
  writing; exact signatures may drift. Check `lib/` when in doubt.
- **ASCII diagrams** where possible; Mermaid where ASCII is too
  cramped (GitHub renders Mermaid inline).
- **Cross-links** use relative paths so documents resolve both on
  GitHub and in local preview.
