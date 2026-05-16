# 0014. ATD-generated wire contracts for cross-BC DTOs

- Status: accepted
- Date: 2026-05-16
- Deciders: @emacsway
- Supersedes: —
- Superseded by: —

## Context

Bounded Contexts in this system communicate exclusively through
three categories of serialisable DTOs:

- **CQRS Commands** — accepted by a BC over the bus or HTTP.
- **Integration Events** — emitted by a BC for sibling BCs to
  consume.
- **View Models** — read-side projections of domain aggregates,
  returned by HTTP read endpoints or embedded in IEs.

Per ADR-0001 (hexagonal layout) and the project's BC-independence
rule, **DTOs are not imported across BCs**. A BC that needs to
consume another BC's IE owns its own *mirror* of the wire shape
in `infrastructure/acl/external_view_models/` or
`infrastructure/acl/external_integration_events/`. The mirror
must agree byte-for-byte with the producer's outbound shape; if
it drifts, the bus traffic silently fails to deserialise on one
side and the saga deadlocks.

Today the wire shape is declared by `[@@deriving yojson]` on
hand-written OCaml records. The shapes are nominally typed
(producer and consumer have *different* OCaml types, structurally
similar) and wire-compatibility is upheld by convention rather
than tooling. Two failures already happened:

1. **`Order_accepted_integration_event` between `broker` and
   `paper_broker`.** When `paper_broker` was introduced as the
   in-process substitute for the `broker` BC during backtests,
   its IE was authored from scratch in the new DDD style (flat
   fields, `created_ts` as ISO-8601 string, projected from a
   Domain Event). The pre-existing `broker` IE was left in its
   gateway style (nested `broker_order : Order_view_model.t`,
   `created_ts` as `int64`). The saga that targets either broker
   uniformly cannot parse one if it was tuned for the other.
   Compile-time signal: zero — they are different OCaml types.
   Runtime signal: a backtest run cuts over to live and the
   saga's IE handler raises on the first message.

2. **`reservation_id` ↔ `placement_id` rename
   (commit `2252a0c`).** The rename touched broker and
   paper_broker but missed
   `execution_management/lib/infrastructure/acl/external_integration_events/order_accepted_integration_event.{ml,mli}`,
   where the field is still spelled `reservation_id`. The build
   passes because the test harness constructs the mirror value
   directly; the JSON `t_of_yojson` round-trip across the bus
   would fail at runtime.

Both failures share a shape: a wire contract is implicitly
spread across N OCaml files in N BCs, and any drift in any one
file is invisible at build time. The defensive layer
(integration tests on the actual bus traffic) does catch them
eventually, but only when an end-to-end scenario happens to
exercise the divergent path.

The reference-application thesis we are pursuing demands a
guarantee mechanism strong enough that contract drift cannot
ship. Convention + code review is not sufficient.

## Decision

Adopt **[ATD](https://github.com/ahrefs/atd)** as the
single-source-of-truth declaration of every cross-BC wire
contract, with `atdgen` generating the OCaml types and JSON
codecs at build time.

### Layout

```
shared/contracts/
├── README.md                         — convention summary
└── <bc>/
    ├── commands/                     — CQRS commands accepted by <bc>
    ├── queries/                      — CQRS query DTOs accepted by <bc>
    ├── integration_events/           — IEs emitted by <bc>
    └── view_models/                  — read-side projections of <bc>
                                        domain entities
```

One `.atd` file per wire-relevant type. A BC that consumes a
sibling's outbound contract duplicates the `.atd` under its own
subtree (`<consumer>/external_view_models/` or
`<consumer>/external_integration_events/` — same convention as
the OCaml-side ACL mirror dirs). The cross-BC contract test
(see below) verifies that producer and consumer copies are
byte-for-byte equivalent.

### Generation

Each `.atd` source file is compiled by an inline `dune` rule
into a pair of OCaml modules:

- `foo_t.{ml,mli}` — the record types (`atdgen -t`).
- `foo_j.{ml,mli}` — `yojson_of_t` and `t_of_yojson`
  (`atdgen -j -j-std`).

These two files are **fully owned by atdgen** — they are
generated on every build and any manual edit is lost. They
replace the hand-written `*.{ml,mli}` records carrying
`[@@deriving yojson]` that exist today.

### Methods on DTOs

Many DTOs carry hand-written methods alongside their type
declaration:

- `type domain = …` — what domain value this DTO represents.
- `let of_domain : domain -> t` — projection from the domain
  value.
- Occasionally `let to_domain` or `let validate` for the inverse
  with `Rop.t` error accumulation.

These live in a **hand-written wrapper module** that `include`s
the generated parts:

```ocaml
(* broker/lib/application/view_models/order_view_model.ml *)
include Order_view_model_t   (* atdgen: type t and embedded types *)
include Order_view_model_j   (* atdgen: yojson_of_t, t_of_yojson *)

type domain = Order.t

let of_domain (o : domain) : t = { … }
```

The wrapper module is the public surface — callers continue to
write `Broker_view_models.Order_view_model.of_domain`. The
split is invisible at use sites.

### Cross-BC contract test

For every wire-cross-BC type, `shared/tests/contract/` contains
a test that:

1. Loads a canonical JSON sample.
2. Deserialises the sample into each consumer BC's type via the
   atdgen-generated `t_of_yojson`. All must succeed.
3. Round-trips: serialise the producer's `t` to JSON, deserialise
   into each consumer's `t`, assert the resulting JSON is
   structurally equal.

Test failure is a CI block. Sample values exercise every field
including optional ones — adding an optional field to a contract
without populating it in the sample defeats the test's coverage
and is caught at code review.

## Detection workflow

What surfaces when a contract changes:

| Change | Signal |
|---|---|
| Required field added / removed / typed-changed | Compile error in every BC that builds the record literal or pattern-matches |
| Field renamed in JSON wire (`<json name="…">`) | Cross-BC contract test fails — producer/consumer round-trip mismatches |
| Optional field added | **Silent** unless the test sample exercises it — convention is that every PR adding an optional field also updates the sample |
| Semantic change (units, encoding) without shape change | Not detectable by tooling — covered by CODEOWNERS + changelog comment in the `.atd` |

## Alternatives considered

### Share a single OCaml library between BCs

Rejected. Violates the ADR-0001 BC-independence principle and
the per-BC duplication rule: shared library means a
schema change ripples across all consumers in one PR, which is
exactly the coupling the duplication rule prevents. We want
each BC to update its mirror deliberately, observing the
producer's change.

### JSON Schema + runtime validation

Rejected. JSON Schema is text-only — no type information leaks
into the OCaml compiler, so adding / renaming / typing a field
remains compile-silent on the consumer side. Detection only at
runtime when a payload that exercises the new field arrives.
ATD gives compile-time detection on the OCaml side and runtime
checks on the JSON side.

### Property-based round-trip only (qcheck), no schema

Rejected as the *primary* mechanism. Property-based tests are
strong but expensive to author for every cross-BC type, and they
require both sides' OCaml types to be linkable into one test
harness — meaning we still need *some* declaration of the wire
shape. Treat qcheck round-trip as a follow-up layer on top of
ATD, not a substitute.

### Continue with `[@@deriving yojson]` and stricter code review

Rejected. Already in place; already failed twice (the two
incidents in Context). The detection cost is shifted to
reviewers, who do not have a mechanical way to compare a `.ml`
in one BC with its mirror in another.

### Lean into ATD: drop the primitive-DTO defensive layer

The hand-written application-layer DTOs (commands, queries,
view models, integration events) carry a primitive shape
(`string`, `int`, `int64`) specifically to keep Value Objects
off the wire boundary. With ATD generating those primitive
shapes — and offering JSON-level input validation — the
hand-written layer is technically redundant: handlers could
parse JSON straight into the generated `_t` type and promote to
Value Objects in one step, skipping the intermediate
application-layer record altogether.

Deferred. Collapsing the layer pushes ATD-generated types deep
into application-layer signatures, turning the library into a
transitive dependency of every in-process call site rather than
a wire-only concern. The current Hexagonal layout — ATD at the
boundary, hand-written wrappers `include`-ing the generated
modules — keeps that coupling local. Revisit once the ATD
dependency has shipped and stabilised in production; the
simplification is a future option, not part of this ADR.

## Consequences

### Easier

- A schema change to a cross-BC type is a single-file edit in
  `shared/contracts/<bc>/<kind>/<name>.atd`. Rebuild detects all
  the call sites that need updating via OCaml compile errors.
- The set of cross-BC contracts is enumerable: `find
  shared/contracts -name '*.atd'`. New contributors can see at a
  glance what crosses BC boundaries without inferring it from
  the codebase.
- Sample-based contract tests scale by adding sample fixtures,
  not by writing imperative test code per type.
- CODEOWNERS scoped to `shared/contracts/` makes contract
  changes intrinsically visible to maintainers of every
  affected BC, regardless of which BC the originating PR
  touches.

### Harder

- An extra build artefact per DTO (`_t.ml`, `_t.mli`, `_j.ml`,
  `_j.mli`) — four files generated from one `.atd`. `dune` clean
  builds must include the generation rule before downstream
  compilation; first-time setup is non-trivial.
- DTOs that carried `[@@deriving yojson]` AND hand-written
  methods now span two files (the generated `_t/_j` modules and
  the hand-written wrapper). Slightly more navigation cost.
- Embedded types (e.g. `Instrument_view_model` referenced inside
  `Order_view_model`) require either inlining in each `.atd` or
  a per-BC atd library that compiles multiple files together
  cross-referencing each other. The chosen route is the
  per-BC library — one dune subdirectory per BC's contracts,
  one set of `<lib>_t.ml` artefacts shared across all `.atd`
  files in that subtree.
- Silent additive changes (optional field) remain a discipline
  problem — atd cannot help here, only test samples + code
  review can.
- atdgen does not natively support ADT variants the way OCaml
  does. Discriminated unions like `Order.kind` (Market |
  Limit | Stop | Stop_limit) are encoded in the wire as a
  flattened record with a `type` tag and per-tag optional
  price fields (`Order_kind_view_model.t` already follows this
  shape). The `.atd` schema captures that flat shape; the
  domain ↔ DTO projection lives in the hand-written wrapper.

## Implementation notes

### `dune` rule shape

A library that owns a set of `.atd` files declares its
generation rule once:

```
(rule
 (deps (glob_files %{project_root}/shared/contracts/<bc>/<kind>/*.atd))
 (targets <name1>_t.ml <name1>_t.mli <name1>_j.ml <name1>_j.mli
          <name2>_t.ml … )
 (action (chdir %{project_root}/shared/contracts/<bc>/<kind>
          (progn
           (run atdgen -t %{deps})
           (run atdgen -j -j-std %{deps})))))
```

The generated files are placed in the library's `_build` dir,
not in `shared/contracts/`. Source tree stays free of build
artefacts.

### Migration path

Migration from the current `[@@deriving yojson]` records is
file-by-file:

1. Pick one DTO module, e.g.
   `broker/lib/application/commands/submit_order_command.ml`.
2. Verify the `.atd` already in `shared/contracts/broker/commands/`
   transcribes the current shape exactly.
3. Wire the dune-rule to generate `submit_order_command_t.ml`,
   `submit_order_command_j.ml`.
4. Strip the hand-written `type t = { … } [@@deriving yojson]`
   from `submit_order_command.ml`; replace with
   `include Submit_order_command_t` and
   `include Submit_order_command_j`.
5. `dune build` to confirm no caller broke.
6. Repeat per DTO. The order is not constrained — a half-migrated
   codebase compiles as long as each individual DTO is internally
   consistent.

The `shared/contracts/` tree is **already populated** with `.atd`
descriptions of all 55 current cross-BC DTOs (commands, IEs,
view models across the 7 BCs). The migration step above does not
require authoring schemas, only wiring the generation rule and
deleting the hand-written record declarations.

### Known divergences captured in current contracts

The current `.atd` files faithfully describe today's state,
including the two known divergences flagged with `DIVERGENCE:`
comments in the schema files themselves:

- `broker/integration_events/order_accepted_integration_event.atd`
  vs `paper_broker/integration_events/order_accepted_integration_event.atd`
  — structural mismatch (nested vs flat, `int64` vs ISO-8601
  timestamp).
- `strategy/view_models/candle_view_model.atd` (`ts : int64`)
  vs `broker/view_models/candle_view_model.atd` (`ts : string`).

These divergences predate this ADR and are tracked as follow-up
work; the ADR establishes the framework that will detect any new
divergence going forward.
