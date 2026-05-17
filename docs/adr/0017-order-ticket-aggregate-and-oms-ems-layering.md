# 0017. OrderTicket aggregate + OMS / EMS layering inside execution_management

- Status: accepted
- Date: 2026-05-17
- Deciders: @emacsway

## Context

`execution_management` was originally a single layer: the
`Order_process_manager` saga reserved cash with Account,
then drove the broker leg through fills and rejections directly.
This conflated two concerns at very different levels of detail:

- **Cash reservation** — a one-shot, cross-BC choreography over
  Account. Single decision point, two outcomes, no rich domain
  invariants.
- **Slicing the trader's intent into placements** — a long-lived
  lifecycle with strategy-specific scheduling, fill aggregation,
  the global `Σ filled ≤ total` invariant, terminal absorbtion
  of late events, and operator cancel with broker-side
  acknowledgement.

A single saga that owned both ended up sprawling. The slicing
concern wants an aggregate with rich invariants; the reservation
concern wants a finite state machine. Forcing them into the same
shape made each one worse.

The OMS / EMS distinction is the industry vocabulary for this
split:

- **OMS (Order Management System)** — owns the *order book* of
  approved intents and the working-capital plumbing
  (reservations, terminal states).
- **EMS (Execution Management System)** — owns the *execution
  trajectory*: how an order becomes one or more placements at a
  venue.

## Decision

### Split execution_management into OMS and EMS layers

Inside the same Bounded Context:

```
execution_management
├─ OMS layer
│  └─ Order_process_manager (saga)
│       Trade_intent_approved → Reserve → {Done | Compensated}
│
└─ EMS layer
   └─ OrderTicket aggregate + Placement entity + 6 strategies
        Open → Working → {Filled | Cancelled | Failed}
```

The saga's scope is narrowed to **reservation only**. Once
`Amount_reserved` lands, the saga reaches a terminal `Done`
state and the OrderTicket aggregate takes over.

### OrderTicket aggregate

```
OrderTicket.t
├─ ticket_id           (Ticket_id.t, derived from saga reservation_id)
├─ intent              (Trade_intent.t — what to execute)
├─ directive           (Execution_directive.t — how to execute)
├─ strategy            (Strategies.Strategy.t — closed variant)
├─ placements          (Placement.t list — fan-out of the strategy)
├─ progress            (Progress.t — Σ filled, Σ fees, remaining)
└─ lifecycle           (Working | Cancelling | Filled | Cancelled | Failed)
```

Operations are pure functions returning `t * event list`. The
aggregate enforces the global invariants — the strategy proposes
and the aggregate disposes (see ADR 0016).

Placement is an Entity within OrderTicket (id + linear status
lifecycle), not a Value Object — it accumulates state through
its lifetime.

### Hand-off via in-process function port

The saga's terminal transition emits a `Dispatch_open_ticket`
command. This **does not** go on the bus. The project's rule
(CLAUDE.md / ADR 0001) forbids a model inside a BC from
publishing a Command to itself — a future Transactional Outbox
would otherwise split the saga commit and the aggregate-open
work into two transactions whose interleaving has no benefit
and whose failure mode is recovery debt.

Instead, the factory wires a closure: on
`Dispatch_open_ticket`, invoke
`Open_order_ticket_command_workflow.execute` directly,
in-process, under the same lock as the saga's transition. This
mirrors the established ACL pattern where an inbound IE handler
calls an own command_workflow directly.

```
saga.transition (Amount_reserved ev)
    → Done + [Dispatch_open_ticket{...}]
factory.dispatch (Dispatch_open_ticket cmd)
    → Open_order_ticket_command_workflow.execute cmd
        → OrderTicket.open_ticket
        → Strategy.init
        → Placement_dispatched events
        → publish via bus → broker.Submit_order_command
```

### Bridge: placement_id wire encoding

The aggregate mints local sequence ids per ticket
(1, 2, 3, ...). The broker needs globally unique ids. The
factory encodes:

```
wire_placement_id = ticket_id * 1_000_000 + local_seq
```

The encoding is reversible: inbound broker IEs are decoded back
to `ticket_id` at the ACL boundary, and the apply_* command
workflow finds the right aggregate by that key. The aggregate
itself never sees the wire form.

### Broker-IE → aggregate command routing

Every broker IE that affects placement state crosses the ACL as
an apply_placement_* command:

| Inbound IE              | ACL handler                            | Aggregate operation             |
|-------------------------|----------------------------------------|---------------------------------|
| Order_accepted          | order_accepted_..._handler             | on_placement_acknowledged       |
| Order_filled            | order_filled_..._handler               | on_placement_fill               |
| Order_rejected          | order_rejected_..._handler             | on_placement_rejection          |
| Order_unreachable       | order_unreachable_..._handler          | on_placement_unreachable        |
| Order_cancelled         | order_cancelled_..._handler            | on_placement_cancelled          |

The aggregate's terminal events fan out: `Ev_ticket_completed`,
`Ev_ticket_cancelled`, `Ev_ticket_failed` each trigger
`Release_command` to Account; the corresponding outbound IE is
published independently for telemetry consumers.

## Consequences

**Easier:**

- Two narrow concerns, two appropriate shapes: a saga for
  cross-BC orchestration, an aggregate for rich-invariant
  domain state.
- The aggregate is the single source of truth for `Σ filled`,
  terminal absorbtion, cancel idempotency — no two places ever
  compute these.
- A future durable persistence backend swaps in behind the
  `Ticket_store` port without touching the saga or the
  aggregate (ADR 0018).
- The function-port hand-off keeps the saga commit and the
  aggregate-open work in the same transactional unit. When a
  Transactional Outbox lands later, no rework needed at this
  seam.

**Harder:**

- Two state machines instead of one. Failure modes have to be
  reasoned about at both layers — but each layer's failure mode
  is now well-scoped (saga compensates by NOT dispatching the
  hand-off; aggregate terminates and releases the reservation).
- The factory grows two more side tables —
  `correlation_by_ticket` and `ticket_intent` — to carry
  context the aggregate doesn't own across the hand-off.

**To watch for:**

- The placement_id encoding (`ticket_id * 1_000_000`) caps a
  single ticket at 999_999 placements. The strategies that fan
  out the most (TWAP at minute granularity over a full session)
  emit ~400 placements; the ceiling is comfortable but bears
  noting.
- The function-port closure inside the factory should remain
  the **only** in-process-cross-component invocation in EM. Any
  second such case suggests one of them belongs over the bus.

## References

- ADR 0001 — Hexagonal Architecture (the layering and
  BC-independence rules this ADR honours).
- ADR 0006 — Per-aggregate domain layout (the directory shape
  for OrderTicket / Placement).
- ADR 0011 — Risk-evacuation and Place-Order saga (the
  pre-existing OMS-shaped saga this ADR repositions).
- ADR 0013 — Clock injection (every aggregate operation takes
  `~now`).
- ADR 0016 — Execution-strategy abstraction (what the aggregate
  embeds).
