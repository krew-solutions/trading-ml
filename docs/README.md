# Documentation

This directory contains the design and architecture documentation
for an algorithmic-trading system written in OCaml. The project
streams market data, runs indicator-and-strategy pipelines, and
routes signals through a broker-agnostic order layer to live
brokers (Finam, BCS) or a paper simulator. For installation,
quickstart and CLI reference see the top-level
[`README.md`](https://github.com/krew-solutions/trading-ml/blob/main/README.md).

## Why OCaml

OCaml is a practical, industrially-proven functional language
designed by researchers and used where correctness matters more than
hype. Three things drove the choice for this system:

- **Speed + reliability.** OCaml compiles to efficient native code
  comparable to C/C++ on numeric workloads, yet runs a GC and never
  segfaults. A backtest that touches millions of bars stays
  predictable both in throughput and memory.
- **A type system that models the domain.** Variants, records, and
  module signatures make invariants explicit: an `Order` can be
  `New | Partially_filled | Filled | …` but never an invalid
  in-between state; a `Signal` carries its `Instrument` by
  construction. The compiler refuses to build code that contradicts
  the model — the same property that keeps [Jane Street's trading
  stack][jane-street] safe under pressure.
- **Formal-methods ecosystem.** OCaml is the implementation
  language behind proof assistants like Coq/Rocq and F* — the same
  tools that verify cryptographic libraries and proof-oriented
  languages (Lean, F*). If a piece of the risk layer ever needs
  mechanical verification, the path is open and well-trodden.
  OCaml has a rich ecosystem of [automated formal verification][proof]
  (Gospel, Cameleer, Ortac, QCheck-STM, CFML, Why3, Coq/Rocq).

The language is developed by [INRIA][inria] (French national
research institute) and stewarded by the [OCaml Software
Foundation][osf]; fintech companies like Jane Street drive much of
the industrial tooling. It's "a language by scientists for
scientists" that also pays professional bills.

For a broader personal take see
[*Why I chose OCaml as my primary language*][xvw-why-ocaml] by
Xavier Van de Woestyne.

## Why OCaml pairs well with LLM-assisted development

LLMs are stochastic code generators — every line is a guess shaped
by training, and the only way to converge on correct output is a
fast, specific feedback loop. OCaml gives exactly that, more than
most languages:

- **Compiler as reviewer.** The OCaml type-checker rejects
  mismatched variants, wrong arities, missing cases in pattern
  matches, and signature/implementation drift — usually in one
  pass, with precise line-level errors. An LLM loop that "compile →
  read errors → fix" converges in seconds, not minutes.
- **Types that force modeling, not just annotation.** Writing a
  `.mli` signature or a variant type ahead of implementation pins
  down the shape of the problem. An LLM that reads a good signature
  produces code that already lines up with the domain; the few
  remaining mistakes are caught at compile time rather than at
  runtime.
- **Exhaustiveness and totality.** Pattern-match warnings turn
  "forgot a case" into a compile error. When an LLM adds a new
  variant constructor, every downstream match lights up — no silent
  fall-throughs, no runtime surprises.
- **Functional paradigm controls complexity.** Immutability and
  pure functions by default make code easier to reason about both
  for humans and for statistical models: side effects are visible
  in types (`Eio`, `Mutex`), data flows from input to output
  without hidden global state, and composition is the primary
  reuse mechanism instead of inheritance. An LLM asked to extend a
  small pure function rarely breaks unrelated modules.
- **Pathway to formal verification.** As components stabilize, the
  same OCaml ecosystem (Coq/Rocq, F*, QuickCheck-style generators)
  lets humans — and, increasingly, LLM-assisted workflows — prove
  key properties rather than hope they hold. That upper bound on
  "how much correctness is achievable" is a real ceiling other
  mainstream languages don't offer.

The net effect: the model-level reasoning the type system demands
nudges LLM output toward well-factored designs, and the compiler's
fast, specific feedback catches the rest.

[proof]: https://github.com/ocaml-gospel/gospel?tab=readme-ov-file#tools-using-gospel
[jane-street]: https://blog.janestreet.com/
[inria]: https://www.inria.fr/
[osf]: https://ocaml-sf.org/
[xvw-why-ocaml]: https://xvw.lol/en/articles/why-ocaml.html

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
8. [Gradient-boosted trees](architecture/ml/gbt.md) — pure-OCaml
   inference over LightGBM text-dump models; training pipeline;
   how `Gbt_strategy` plugs into the engine.
9. [Logistic regression](architecture/ml/logistic_regression.md) —
   lightweight classifier as a gating function for the
   `Composite.Learned` policy; SGD + L2 in ~70 lines.

## How-to guides

Step-by-step walkthroughs for common tasks. Unlike the
architecture docs (which explain *why*), these focus on *how*:
concrete commands, expected output, troubleshooting.

- [Train and deploy a GBT strategy](howto/ml/gbt.md) — end-to-end
  pipeline from historical bars to a live-running model.
- [Train and deploy a logistic gate](howto/ml/logistic_regression.md) —
  in-process OCaml training for the `Composite.Learned` policy;
  no Python, weights are a 10-scalar array.

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
