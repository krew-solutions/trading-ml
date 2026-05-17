# 0018. In-memory ticket store as transitional persistence

- Status: accepted
- Date: 2026-05-17
- Deciders: @emacsway

## Context

The OrderTicket aggregate (ADR 0017) needs persistence:

- Every apply_placement_* command workflow loads the current
  aggregate, applies a domain operation, saves the result, and
  publishes the emitted events.
- The HTTP query routes (`GET /api/order-tickets`,
  `GET /api/order-tickets/{id}`) read the same store.
- The scheduler-driven `advance_strategy_clock_command` fans
  ticks out to every non-terminal ticket via the store's
  `all_open`.

A durable persistence backend (Postgres / EventStore) is a
non-trivial trajectory in itself: schema design, snapshot
versus event-sourced layout, transactional boundaries that
align with the command workflow, snapshotting policy. None of
that is on the critical path for the current milestone (six
strategies running end-to-end on a single host).

A precedent exists. `Workflow_engine.In_memory_store` has
served the saga layer since `Open_order_ticket_process` landed
and is the canonical shape for transitional persistence in this
codebase.

## Decision

Ship a `Ticket_store.S` hexagonal port with a single in-memory
adapter, modelled on `Workflow_engine.In_memory_store`.

### Port

```
module type Ticket_store.S = sig
  type t

  val get        : t -> Ticket_id.t -> Order_ticket.t option
  val put        : t -> Order_ticket.t -> unit
  val all_open   : t -> Order_ticket.t list
  val active_count : t -> int
end
```

The port is the boundary every command workflow and query
handler depends on. The composition root chooses the adapter.

### Adapter: In_memory_ticket_store

A `Hashtbl` keyed by `Ticket_id.t` plus a `Mutex` to serialise
writes. `all_open` filters out terminal tickets. Concurrency
semantics:

- The factory's outer mutex serialises every command workflow
  per BC (already in place for the kill-switch / rate-limit
  state).
- Inside the store, the per-call `with_lock` defends `Hashtbl`
  atomicity. There is no per-ticket lock — the factory's outer
  mutex makes one redundant.

### Out of scope

- **Transactional semantics across multiple commands.** Every
  command workflow is its own transaction by convention; the
  in-memory adapter does not implement isolation levels.
  A durable backend will.
- **Crash recovery.** Process restart loses every non-terminal
  ticket. This is acceptable for the current milestone (live
  trading is not the only consumer; backtest reseeds the store
  every run).
- **Event-sourced replay.** Today the store snapshots full
  aggregate values. A future durable backend may snapshot
  periodically and replay the event tail; the port stays the
  same.

## Migration path to a durable backend

When the durable backend lands:

1. Add `Persistence.Postgres_ticket_store` (or similar) under
   `execution_management/lib/infrastructure/persistence/`.
2. The composition root swaps the adapter argument; no
   workflow / query / domain code changes.
3. Migration of in-flight tickets across the cutover is a
   one-shot replay against the new backend, fed from the bus's
   replayable IE stream (every aggregate event is already
   published).

The port surface is intentionally minimal so that this swap
stays a configuration change.

### Mirror with ADR 0005

This decision mirrors the trajectory of the account-reservations
ledger (ADR 0005): an in-memory ledger shipped first, with a
durable backend planned along the same port. Two BCs, one
pattern; durable persistence rolls out in a separate consistent
trajectory rather than piecemeal per BC.

## Consequences

**Easier:**

- The full OrderTicket lifecycle works end-to-end without
  blocking on persistence design.
- Tests use the same adapter the production code uses (sociable
  unit tests + BDD scenarios both bind against
  `In_memory_ticket_store`).
- Swap-in of a durable backend is a port-level concern, not an
  aggregate refactor.

**Harder:**

- Process restart is destructive to in-flight tickets. Live
  trading without a durable backend means accepting that
  failure mode — or operating only in modes where restarts are
  rare and operator-driven.
- Multi-process / multi-host deployment is not supported by
  this adapter. A single OS process is the consistency
  boundary.

**To watch for:**

- Any new operation that breaks the "load → apply → save →
  publish" cycle (e.g., partial updates across multiple
  aggregates) is the smell that the in-memory adapter is
  shielding the design from real durability concerns. Don't
  build for that case on the in-memory adapter — design for it
  on the durable one.
- The mutex inside `In_memory_ticket_store` is **separate**
  from the factory's outer mutex. If a future factory variant
  drops the outer lock (e.g., per-ticket parallelism), the
  in-store lock alone is insufficient — read-modify-write
  cycles need the higher-level guarantee.

## References

- ADR 0001 — Hexagonal Architecture (the port / adapter shape).
- ADR 0005 — Reservations ledger (the parallel transitional
  in-memory adapter on the Account side).
- ADR 0017 — OrderTicket aggregate (the consumer of this port).
