# 0006. Per-aggregate domain layout

**Status**: Accepted
**Date**: 2026-04-28

## Context

CLAUDE.md (Domain Layer section) requires that every Bounded Context
arrange its `domain/` directory as a list of aggregate
sub-directories. Each aggregate sub-directory contains:

- `values/` — ValueObjects;
- `events/` — DomainEvents;
- a separate sub-directory **per Entity** (Entities differ from
  ValueObjects by having identity and a lifecycle); if an Entity
  itself owns ValueObjects, DomainEvents, or nested Entities, the
  Entity's sub-directory recursively repeats the aggregate's
  shape.

Account is the first BC in the project with a real Domain Layer
(Broker has none, `shared/` has none). Until this ADR the
Account domain was a single 252-line monolithic file
`account/lib/domain/portfolio.ml` that bundled the aggregate root
`Portfolio.t`, the Entity `reservation`, the VO `position`, two
DomainEvents (`amount_reserved`, `reservation_released`), and two
business-rule error types — exactly the kind of mixing the
CLAUDE.md schema is designed to forbid.

The reorganisation of Account establishes the canonical pattern
that the next BC with a domain layer must follow.

## Decision

Adopt per-aggregate sub-directories with the recursive shape
described above, dune `(include_subdirs qualified)` namespacing,
and one consistent file-naming rule applied at every level: the
"main module" of a directory is a file whose name matches the
directory. The same rule applies to:

- `portfolio/portfolio.ml` — aggregate root;
- `portfolio/reservation/reservation.ml` — Entity main file;
- (when Reservation grows nested entities) the same recursive shape.

```
account/lib/domain/
├── dune                                   # (include_subdirs qualified)
└── portfolio/
    ├── portfolio.ml/.mli/.mlw             # aggregate root + re-exports
    ├── reservation/
    │   └── reservation.ml/.mli/.mlw       # Entity (id + lifecycle)
    │   (if Reservation grows VOs/events of its own, they go into
    │    reservation/values/ and reservation/events/ — the Entity
    │    directory recursively repeats the aggregate shape)
    ├── values/
    │   └── position.ml/.mli/.mlw          # VO
    └── events/
        ├── amount_reserved.ml/.mli/.mlw      # DomainEvent
        └── reservation_released.ml/.mli/.mlw # DomainEvent
```

Module paths after compilation (one dune-library `account` covers
all of `account/lib/domain/`, no nested libraries):

| Concept                | OCaml module                                    | Why3 module path                                            |
|------------------------|-------------------------------------------------|-------------------------------------------------------------|
| Aggregate root         | `Account.Portfolio`                             | `portfolio.portfolio.Portfolio`                             |
| Entity reservation     | `Account.Portfolio.Reservation`                 | `portfolio.reservation.reservation.Reservation`             |
| VO position            | `Account.Portfolio.Values.Position`             | `portfolio.values.position.Position`                        |
| DomainEvent (success)  | `Account.Portfolio.Events.Amount_reserved`      | `portfolio.events.amount_reserved.Amount_reserved`          |
| DomainEvent (release)  | `Account.Portfolio.Events.Reservation_released` | `portfolio.events.reservation_released.Reservation_released`|

Callers reach the aggregate-root API at `Account.Portfolio.X`
directly — no `.Aggregate` (or similar) suffix, no top-of-file
alias required:

```ocaml
let p = Account.Portfolio.empty ~cash:(Decimal.of_int 1_000_000) in
match Account.Portfolio.try_reserve p ~id ... with
| Ok (p', ev) -> (* ev : Account.Portfolio.Events.Amount_reserved.t *)
```

## How the layout works: collapse + explicit re-export

dune `(include_subdirs qualified)` has a sharp behavioural rule:
when a sub-directory contains a file whose name matches the
directory name (`foo/foo.ml`), dune treats that file as the
directory's **main module** and **collapses the sub-directory's
qualified namespace into it**. Peer sub-directories (`foo/bar/`,
`foo/baz/`) become nested submodules **inside** the collapsed
main module — visible from outside only if the main module
explicitly re-exports them.

We make this rule load-bearing in both directions:

- `portfolio/portfolio.ml` is the aggregate-root main module. It
  collapses the `portfolio/` namespace into itself and explicitly
  re-exports the peer sub-namespaces it wants public. By default,
  nothing leaks; the aggregate-root file is the single point that
  declares "Values, Events, Reservation are part of my public
  surface".
- `portfolio/reservation/reservation.ml` is the Entity main
  module. It does the same for the Entity's own scope: any
  internal `reservation/values/` or `reservation/events/`
  sub-directories the Entity grows are encapsulated inside it
  unless the Entity chooses to re-export them.

The `.ml`/`.mli` re-export idiom (no signature duplication):

```ocaml
(* portfolio/portfolio.mli *)
module Values      : module type of Values
module Events      : module type of Events
module Reservation : module type of Reservation

(* + the aggregate-root API *)
type t = private { ... }
val empty : cash:Core.Decimal.t -> t
...
```

```ocaml
(* portfolio/portfolio.ml *)
module Values      = Values
module Events      = Events
module Reservation = Reservation

(* + the aggregate-root implementation *)
type t = { ... }
let empty ~cash = { ... }
...
```

`module type of M` copies the full signature of `M` (including
type equalities) without manual repetition; the `.ml`-side alias
`module M = M` connects the published name to the actual peer
sub-directory module.

This is exactly the OCaml/dune analogue of Python's `__init__.py`
or the old Rust `mod.rs`: the file with the directory-matching
name is the namespace's controlled surface, and the author
explicitly chooses what passes through.

## Alternatives considered

### `aggregate.ml` (no name collision, automatic peer-subdir publication)

An earlier draft of this ADR named the aggregate-root file
`aggregate.ml` to avoid dune's collapse rule. That made all peer
sub-directories (`values/`, `events/`, `reservation/`)
automatically exposed under `Account.Portfolio.Values.X`,
`Account.Portfolio.Events.X`, `Account.Portfolio.Reservation`.

Rejected because it produces an asymmetric naming convention
(`aggregate.ml` for roots, `<entity>.ml` for Entities), strips
the aggregate-root file of explicit control over its public
surface, and forces callers to write `Account.Portfolio.Aggregate.X`
or carry a top-of-file alias `module Portfolio =
Account.Portfolio.Aggregate`. The `__init__.py`-style explicit
re-export is more canonical and gives encapsulation by default.

### Flat layout, all files at `account/lib/domain/` root

What we had before. Conflicts with CLAUDE.md, mixes VOs / Entities
/ Events / aggregate root in one namespace, doesn't scale to a
second aggregate.

### `entities/` umbrella sub-directory

Earlier draft placed all Entities under a single `entities/`
sub-directory next to `values/` and `events/`. Rejected because:
the aggregate root is itself an Entity (chosen as the
transactional consistency boundary), so splitting "the root
Entity" from "the other Entities" via different directory
placement is semantically incoherent; Vernon (IDDD), Evans (DDD
blue book), and Stöckl (go-iddd) keep the aggregate root and its
supporting Entities at the same level; CLAUDE.md was explicitly
amended to require **a separate directory per Entity**.

### One dune-library per sub-directory

Would give names like `Account_portfolio_values.Position.t`. Plus:
no namespace-collapse mechanics to learn. Minus: snake-case
prefixes, every new sub-directory adds a `dune` file, the
`account` umbrella library no longer covers the full BC.
Rejected — `qualified` mode achieves the same hierarchy with one
library and lets the collapse rule do useful work.

## Consequences

**Easier**:

- One uniform naming rule across the layout: a directory's main
  module is the file whose name matches the directory. Aggregates
  and Entities (and any nested Entity sub-directories) follow it
  identically — no asymmetric exception for the aggregate root.
- Callers reach the aggregate-root API as `Account.Portfolio.X`
  directly — no qualifier suffix, no top-of-file alias.
- Encapsulation is opt-out, not opt-in: the main module file is a
  controlled surface, peer sub-directories don't escape unless
  re-exported. The same mechanism works at Entity scope.
- Each VO / Entity / DomainEvent is a single small file, easy to
  review in isolation. Why3 proofs for per-concept invariants
  live next to their `.mli` and don't pollute the aggregate-root
  proof file.

**Harder**:

- Two short re-export lines per published peer sub-directory
  (`module Values = Values` in `.ml`, `module Values : module
  type of Values` in `.mli`). Minimal boilerplate, but it's the
  author's responsibility to add it whenever they want a new
  peer sub-directory to be publicly visible.
- Why3 imports use the qualified path mechanism; verifying that
  `use portfolio.reservation.reservation.Reservation` resolves
  required threading `-L .` from `account/lib/domain/` through
  the `dune` Why3-rule. The rule already had `-L .` in place
  before this ADR, so the change boiled down to switching
  `glob_files *.mlw` to `glob_files_rec *.mlw`.

**To watch for**:

- The dune collapse rule for file-of-same-name-as-directory is
  load-bearing — accidental rename of `portfolio/portfolio.ml`
  to anything else (or removal) will silently change the
  semantics: peer sub-directories will become automatically
  visible without going through `portfolio.ml`'s controlled
  re-export. Future agents reorganising another BC must keep
  the `<dir>/<dir>.ml` convention at every level.
- All cross-BC references that used `Account.Portfolio.X` (engine,
  paper broker, queries, tests) had to be updated when the
  monolithic file was split into per-concept files. Future
  refactors of other BCs should expect a comparable blast radius
  whenever an aggregate's surface is reorganised.

## References

- CLAUDE.md, section "Domain Layer".
- Plan file: `/home/ivan/.claude/plans/graceful-cooking-thimble.md`.
- Vernon, *Implementing Domain-Driven Design*, ch. 10
  (Aggregates) for the conceptual decomposition.
- Wlaschin, *Domain Modeling Made Functional*, ch. 4–9 for the
  VO / Entity / DomainEvent vocabulary as it applies to a
  functional setting.
