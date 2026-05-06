# Functional hexagonal

This document covers the *application layer* structure: how
commands, events, workflows and DTO projections fit into the
hexagonal skeleton from [`overview.md`](overview.md).

The base hexagonal rules (domain at the center, application
orchestrating, infrastructure at the edges) still apply. What's
added here is a functional-programming flavor of the same
pattern, in the spirit of Scott Wlaschin's *Domain Modeling Made
Functional*: pure pipelines, typed events, accumulating
validation, no mutable aggregates.

## Layered picture

The codebase is split into bounded contexts. Each BC has the
same internal three-layer shape; the picture below describes
the layout of a single BC (Account is used as the running
example):

```
┌──────────────────────────────────────────────────────────────────────┐
│ <bc>/lib/infrastructure/                                             │
│   inbound/http/             ← HTTP routing, JSON ↔ command DTO       │
│   acl/                      ← anti-corruption to external venues     │
│   acl/inbound_integration_events/                                    │
│                             ← cross-BC inbound translation           │
│   persistence/              ← state snapshots, event store           │
└──────────────────────────────────────────────────────────────────────┘
                              ▲
                              │ calls
┌──────────────────────────────────────────────────────────────────────┐
│ <bc>/lib/application/                                                │
│                                                                      │
│   commands/                 ← <name>_command.ml         (DTO)        │
│                               <name>_command_handler.ml             │
│                                          (validate + aggregate call) │
│                               <name>_command_workflow.ml             │
│                                          (handler + publishers)      │
│                                                                      │
│   domain_event_handlers/    ← reactors for single domain events      │
│   queries/                  ← read-side view models (DTO)            │
│   integration_events/       ← outbound DTO events for other BCs      │
│   ports/                    ← outbound module signatures             │
└──────────────────────────────────────────────────────────────────────┘
                              ▲
                              │ uses
┌──────────────────────────────────────────────────────────────────────┐
│ <bc>/lib/domain/  (pure)                                             │
│   <aggregate>/              ← e.g. portfolio/                        │
│     <aggregate>.{ml,mli,gospel,mlw}                                  │
│     events/                 ← one file per domain event              │
│     values/                 ← Value Objects                          │
│   core/                     ← shared domain primitives               │
│                                                                      │
│   No IO, no external deps. Gospel / Why3 sidecars carry              │
│   formal specs.                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

Cross-BC traffic (Account ↔ Broker, etc.) flows through
integration events on the bus layer in `shared/lib/bus/`; no
BC's library imports another BC. The composition root in
`bin/main.ml` wires every BC's bus, publishers, HTTP adapter
and any cross-BC ACL bridge.

## Application sub-layers

### `commands/` — what the system receives

An inbound **command** is a user-initiated action: "reserve cash
for this order", "release this reservation". Each command is
expressed by **three sibling files** in the same
`commands/` directory:

- **`<name>_command.{ml,mli}`** — the wire-format DTO.
  Primitive-typed, `[@@deriving yojson]`, no Value Objects.
  Sent by HTTP, CLI, message bus, or any other transport — the
  command module says nothing about how the bytes arrived.
- **`<name>_command_handler.{ml,mli}`** — accepts the wire-format
  command and is responsible for the entire single-command
  step: parse the DTO into domain types, invoke the aggregate,
  return the resulting domain event or a typed failure. Parse
  is encapsulated as a private internal phase; only `handle` is
  exported.
- **`<name>_command_workflow.{ml,mli}`** — the ROP pipeline
  composing the handler with the integration-event publishers.
  One success-side projection, optionally one failure-side
  projection.

A command's failure track is a typed union (`handle_error`),
never a string. The variant carries enough context for the
workflow to populate any failure-side integration event without
re-parsing the original DTO.

For the typing rules behind `handle_error`, the applicative
versus monadic split, and why `validate` is private rather than
exported alongside `handle`, see [`rop.md`](rop.md).

### `domain_event_handlers/` — what the system does in response

A **domain-event handler** reacts to **one** domain event.
Files are named for the *what* the handler does (and *when*),
not how it does it: e.g.
`publish_integration_event_on_amount_reserved.ml`,
`publish_integration_event_on_reservation_released.ml`. Each
file has one function:

```ocaml
val handle :
  publish_amount_reserved:(Amount_reserved_integration_event.t -> unit) ->
  Account.Portfolio.Events.Amount_reserved.t ->
  unit
```

Handlers are **source-agnostic**: they care about the event
type, not the workflow that produced it. The same projection
runs whether `Amount_reserved` came from a manual
`Reserve_command` or from a future strategy-driven flow. This
asymmetry — multiple subscribers per event versus one handler
per command — is the reason domain-event handlers are
extracted into their own modules while command handlers are
not.

### `commands/<name>_command_workflow.{ml,mli}` — pipeline file

The workflow is **not** a separate sub-directory; it is the
third sibling of the command and the command handler in the
same `commands/` directory:

```
commands/
  reserve_command.{ml,mli}              wire DTO
  reserve_command_handler.{ml,mli}      validate + aggregate call
  reserve_command_workflow.{ml,mli}     handler + integration-event publishers
```

The workflow body is one match over the handler's outcome
calling integration-event publishers on each branch:

```ocaml
let execute ~portfolio ~next_reservation_id ~slippage_buffer ~fee_rate
    ~publish_amount_reserved ~publish_reservation_rejected
    (cmd : Reserve_command.t)
    : (unit, Reserve_command_handler.handle_error) Rop.t =
  match
    Reserve_command_handler.handle ~portfolio ~next_reservation_id
      ~slippage_buffer ~fee_rate cmd
  with
  | Ok domain_event ->
      Account_domain_event_handlers
      .Publish_integration_event_on_amount_reserved.handle
        ~publish_amount_reserved domain_event;
      Rop.succeed ()
  | Error errs ->
      List.iter
        (function
          | Reserve_command_handler.Reservation { attempted; error } ->
              publish_reservation_rejected
                (build_rejection_event attempted error)
          | Reserve_command_handler.Validation _ -> ())
        errs;
      Error errs
```

The workflow returns the handler's `handle_error` directly —
it does not wrap it in a workflow-local error sum. Composition
is explicit OCaml; there is no event-bus indirection between
the workflow and its handler.

Why no validation-side integration event in the example: a
malformed wire payload never reached the aggregate, so there
is nothing for the workflow to broadcast as a "rejection";
validation failures surface only through the `Rop.t` tail.
See [`rop.md`](rop.md) for the typing rationale.

### `integration_events/` — outbound event DTOs

**Why a separate type at all.** A domain event carries *Value
Objects* from the domain layer — `Instrument.t`, `Side.t`,
`Decimal.t`, etc. These are opaque, private, invariant-carrying
types: `Ticker.t` is a `private string` constrained to
upper-case no-whitespace; `Decimal.t` is fixed-point with a
specific scale; `Instrument.t` is a private record whose
constructor rejects malformed venues. **None of these can be
serialised directly.** Out-of-process consumers (HTTP, message
bus, WebSocket, audit database) need primitive types: strings,
floats, ints.

So to send an event across a process boundary, a handler must
convert it into an **integration event** — a primitive-typed
copy. This is exactly analogous to the way we project
**domain models** (`Core.Order.t`, `Engine.Portfolio.t`) into
**view models** for read endpoints:

| | Domain (Value Objects, private types) | Outbound DTO (primitives, serialisable) |
|---|---|---|
| State snapshot | `Core.Candle.t` | `Candle_view_model.t` |
| Happening | `Portfolio.amount_reserved` | `Amount_reserved_integration_event.t` |

Same contract shape (`of_domain` + `yojson_of_t`), different
semantic — one captures *current state*, the other captures
*what happened*.

Each domain event has a matching integration event: a
primitive-typed `[@@deriving yojson]` copy with an `of_domain`
conversion.

These exist so a future message bus, WebSocket, or audit log can
subscribe to the workflow's events without re-implementing
projection. The workflow itself doesn't depend on
`integration_events` — the adapter projecting to a channel does.

### `queries/` — read-side view models

For read endpoints (`GET /api/orders`, etc.), domain entities are
projected into VMs in the same way:

```
Core.Candle.t  →  Candle_view_model.of_domain  →  primitive record + yojson
```

Contract: each BC's `application/queries/view_model.ml` declares
the `module type S` that every view model in that BC conforms
to (`account/lib/application/queries/view_model.ml`,
`strategy/lib/application/queries/view_model.ml`). Conformance
is enforced at compile time by the `queries/compile_checks.ml`
sibling.

### `rop/` — accumulating Result

`Rop.t = ('a, 'err list) result`: a thin layer over stdlib
`Result` whose Error branch always carries a list, so parallel
branches can concatenate failures rather than picking one
arbitrarily. Provides applicative `let+ / and+` for parallel
accumulation and monadic `let*` for sequential short-circuit.

The full operator surface, the validation-accumulation pattern,
and how it shapes command-handler signatures live in
[`rop.md`](rop.md).

### `<bc>/lib/application/ports/` — outbound module signatures

Outbound ports live in the BC that drives them. The Broker BC
declares `Broker.S` in `broker/lib/application/ports/broker.ml`;
its `Submit_order_command_handler` programs against the
existential `Broker.client`, so swapping a concrete venue
(Finam / BCS / Paper) is a one-line wiring change at the
composition root. See
[`overview.md`](overview.md#the-core-abstraction-brokers) for
the historical motivation of the port style.

## Domain events

Events are facts about aggregate state changes. They live
**inside the aggregate** that emits them, not in the command
module that happens to trigger the aggregate call. Each event
type is its own file under the aggregate's `events/`
sub-directory; the aggregate's public methods return the
matching event in their `Ok` branch.

```
account/lib/domain/portfolio/
  portfolio.mli:
    val try_reserve :
      t -> id:int -> side:Side.t -> instrument:Instrument.t ->
      quantity:Decimal.t -> price:Decimal.t ->
      slippage_buffer:Decimal.t -> fee_rate:Decimal.t ->
      (t * Events.Amount_reserved.t, reservation_error) result
    val try_release :
      t -> id:int ->
      (t * Events.Reservation_released.t, release_error) result
  events/
    amount_reserved.{ml,mli,gospel,mlw}
    reservation_released.{ml,mli,gospel,mlw}
```

The aggregate method emits the event as part of its return
value; there is no mutable event bus inside the aggregate
(that is the Vaughn-Vernon accumulator style — this codebase
uses the Wlaschin-style return-tuple form). The Gospel /
Why3 sidecars sit beside the `.ml` to carry formal
specifications.

Domain events of the Account bounded context drive a cross-BC
saga rather than a single in-process workflow. Account emits
`Amount_reserved`; Broker reacts by submitting the order to the
external venue; Broker emits `Order_accepted` /
`Order_rejected` / `Order_unreachable`; an Account-side
inbound ACL projects the rejection variants back into a
`Release_command`, closing the compensation. See
[*Cross-BC place-order saga*](#cross-bc-place-order-saga)
below for the full flow.

## Stable wire contract

**Rule: domain events never cross the HTTP boundary.**

Two reasons:

1. **Information disclosure.** Internal ids, broker error
   strings, state-machine topology — none of that should leak to
   a public client. Events are designed for internal trust
   zones.
2. **Coupling.** If the browser parses event shapes, every
   internal refactor (rename, split, add field) breaks the
   frontend. A stable public response insulates the client from
   domain evolution.

The Account inbound HTTP adapter accepts `POST /api/orders`
and immediately returns `202 Accepted` with a placeholder body;
no synchronous broker outcome is encoded in the response.
The actual reservation outcome and any subsequent
broker-driven status flow are delivered to the UI through the
SSE stream of integration events, which is the only channel
where status transitions surface. The 202 response is a
deliberate consequence of the asynchronous command bus —
`Reserve_command_handler.handle` runs through the bus
fire-and-forget — and the SSE stream subscribes to the
`Amount_reserved` / `Reservation_rejected` / `Order_accepted` /
`Order_rejected` integration events.

Adding a new domain event inside any single bounded context
changes the internal type but not the wire contract. Adding a
genuinely new *terminal business outcome* (a new integration
event a UI subscriber should react to) does change the SSE
contract — and that is a deliberate product decision, not a
refactor side effect.

## Direction of knowledge

```
infrastructure → knows → application
application   → knows → domain
domain       → knows → (nothing outside itself)

queries / integration_events ← project ← domain entities / events
```

Each bounded context is laid out as `<bc>/lib/{domain,application,infrastructure}/`
with the same internal sub-layering. Within one BC's
`application/`:

- `commands/` imports the BC's domain library plus `core`,
  `queries`, `rop`. Exposes `<name>_command.t` (DTO),
  `<name>_command_handler.handle`, and `<name>_command_workflow.execute`.
- `domain_event_handlers/` imports the BC's domain library plus
  `integration_events`. Each handler is a single function
  reacting to one domain event.
- `integration_events/` imports the BC's domain library plus
  `queries` (for `*_view_model` projections). Holds the typed
  DTOs that other contexts may subscribe to.
- `queries/` imports only the BC's domain library and `core`.

`infrastructure/inbound/http/` for the BC imports anything in
the BC's `application/` it needs. That is the hexagonal
entry-point of the BC. Cross-BC inbound translation lives in
`infrastructure/acl/inbound_integration_events/`.

The composition root in `bin/main.ml` wires every BC's bus,
publishers, HTTP adapter, and any cross-BC ACL subscription —
no BC's library imports another BC.

## Design decisions

Stated once; don't re-argue per command.

1. **Command handlers and domain-event handlers are different
   roles, kept in separate sub-directories.** A *command
   handler* (under `commands/`) is bound to exactly one command
   in exactly one workflow; it owns the entire single-command
   step including validation. A *domain-event handler* (under
   `domain_event_handlers/`) reacts to a single domain event
   and may have multiple subscribers across workflows (DIP) —
   that asymmetry is why it is extracted into its own module.
   See [`rop.md`](rop.md) for the encapsulation rule on the
   command-handler side.

2. **Errors are typed unions, never strings.** Every
   `validation_error`, `reservation_error`, `release_error`,
   `handle_error` is a discriminated union. Strings are for
   humans; code pattern-matches types. A single
   `*_to_string` projection per error type produces the human
   channel (the `reason` field of a rejection integration
   event).

3. **Domain events are aggregate-level.** Emitted by
   `Portfolio.try_reserve` / `Portfolio.try_release`, not
   synthesised by the command handler from parameters. The
   aggregate is the source of truth for "what happened to me".

4. **Compensation is a railway switch, not an undo.**
   The Account inbound ACL handler reacting to
   `Order_rejected_integration_event` is a *normal* handler
   that dispatches a `Release_command`. There is no
   SAGA-style rollback — the reservation was never
   "committed" past the earmark, so releasing it is a forward
   action on a different track of the cross-BC saga.

5. **Workflows are explicit OCaml composition, not bus magic.**
   A workflow's body is a `match` over the handler's outcome
   that calls integration-event publishers on each branch.
   The bus carries commands and events; the workflow makes the
   decisions.

6. **Integration events are the only cross-BC currency.**
   They are DTO-shaped, primitive-typed, `[@@deriving yojson]`,
   and live in `application/integration_events/` (outbound) or
   `infrastructure/acl/inbound_integration_events/` (inbound).
   No BC's library imports another BC; everything cross-BC
   travels through the bus, encoded as integration events.

7. **Naming: `cmd`, not `dto`.** DTO is an architectural
   category (data transfer); `cmd` says what it is semantically
   (a command). View models are `Candle_view_model`, not
   `Candle_dto`. Integration events are `*_integration_event`.
   Type describes intent.

8. **`let+ / and+` for applicative, `let*` for monadic.** Parse
   multiple DTO fields in parallel with accumulation — use
   `let+ / and+`. Chain dependent steps — use `let*` or explicit
   `match` (when the failure branch needs compensation). Detail
   in [`rop.md`](rop.md).

## Cross-BC place-order saga

Placing an order is **not** a single in-process workflow but a
saga across the **Account** and **Broker** bounded contexts,
choreographed through integration events on the in-memory bus.
The Account context owns the reservation ledger; the Broker
context owns the conversation with the external venue. Neither
imports the other; they communicate only by publishing and
subscribing to integration events.

```
┌── Account BC ──────────────────────────────────────────────────────┐
│                                                                    │
│  POST /api/orders ──► Reserve_command (DTO, strings)               │
│                              │                                     │
│                              ▼  (Command_bus.send, fire-and-forget) │
│                       Reserve_command_workflow.execute             │
│                              │                                     │
│                              ▼                                     │
│                       Reserve_command_handler.handle               │
│                              │                                     │
│                              │ validate (private)                  │
│                              │ Account.Portfolio.try_reserve       │
│                              ▼                                     │
│                       Events.Amount_reserved (domain)              │
│                              │                                     │
│                              ▼ (Publish_integration_event_on_…)    │
│                       Amount_reserved_integration_event ──┐        │
│                                                           │        │
│  HTTP responds 202 Accepted; UI gets status via SSE       │        │
└───────────────────────────────────────────────────────────│────────┘
                                                            │
                          (Event_bus, in-process today)     │
                                                            │
┌── Broker BC ──────────────────────────────────────────────│────────┐
│                                                           ▼        │
│                       Submit_order_command (carries reservation_id)│
│                              │                                     │
│                              ▼  (Command_bus.send)                 │
│                       Submit_order_command_handler.make            │
│                              │                                     │
│                              ▼  (Broker.place_order via ACL)       │
│                       Order_accepted | Order_rejected |            │
│                                       Order_unreachable            │
│                              │                                     │
│                              ▼                                     │
│                       *_integration_event ─────────────────┐       │
└────────────────────────────────────────────────────────────│───────┘
                                                             │
┌── Account BC inbound ACL ──────────────────────────────────│───────┐
│                                                            ▼       │
│                       acl/inbound_integration_events/              │
│                       Order_rejected_integration_event_handler     │
│                              │                                     │
│                              ▼  (dispatches Release_command)       │
│                       Release_command_workflow.execute             │
│                              │                                     │
│                              ▼                                     │
│                       Account.Portfolio.try_release                │
│                              │                                     │
│                              ▼                                     │
│                       Reservation_released_integration_event       │
└────────────────────────────────────────────────────────────────────┘
```

Notes on the flow:

- The Account validation step is purely synchronous and
  in-process: the handler returns a typed
  `Reserve_command_handler.handle_error` on a malformed DTO or
  `Reservation { attempted; error }` on insufficient cash /
  quantity. Only successful reservations cross into Broker.
- The Broker step is the only IO call, through the injected
  `Broker.S` port, so the Broker handler does not depend on a
  concrete venue.
- Compensation runs as a normal forward command: an Account
  inbound ACL subscribes to Broker's rejection / unreachable
  events and dispatches a `Release_command` on the Account
  bus. There is no SAGA-style rollback — the reservation was
  never "committed" past the earmark, so releasing it is a
  forward action on a different track.
- Cross-BC type isolation is structural: the inbound ACL has
  its own DTO mirrors of Broker's outbound integration events
  (`account/lib/infrastructure/acl/inbound_integration_events/`),
  populated by a field-copy bridge wired in the composition
  root. Account never types over `Broker_integration_events`
  directly.

## What's *not* here

- **Cross-process buses.** The current bus is in-process Eio
  (`shared/lib/bus/`). When NATS or Kafka arrives, the
  workflows do not change — only the bus implementation
  satisfying `Bus.Event_bus.S` / `Bus.Command_bus.S` does.
- **Synchronous status in the HTTP response.** `POST /api/orders`
  returns `202 Accepted` and the UI subscribes to integration
  events via SSE; a saga key (HTTP-generated correlation id)
  for tying SSE updates back to a request is the next
  HTTP-side step.
- **Other commands.** Only `Reserve_command` / `Release_command`
  (Account) and `Submit_order_command` (Broker) are
  implemented. `CancelOrder`, `RunBacktest`,
  `StartLiveStrategy` are planned.
- **Strict-by-default DTO parsing on every wire boundary.**
  The Account inbound HTTP adapter (`account/lib/infrastructure/inbound/http/http.ml`)
  and the Broker `Submit_order_command_handler` still parse
  with `failwith` / `invalid_arg` rather than the ROP
  validator pattern. Aligning them with
  [`rop.md`](rop.md) is a planned cleanup.

## See also

- [`overview.md`](overview.md) — the base hexagonal structure
- [`rop.md`](rop.md) — Railway-Oriented Programming, command
  handler encapsulation, validation accumulation
- [`domain-model.md`](domain-model.md) — the types flowing
  through commands and events
- [`state-machine.md`](state-machine.md) — how bars become
  intents (this is the strategy-driven path, orthogonal to
  manual commands)
- [`reservations.md`](reservations.md) — how Portfolio earmarks
  cash/qty and the reserve → commit lifecycle
