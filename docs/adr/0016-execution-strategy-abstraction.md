# 0016. Execution-strategy abstraction: closed variant over a shared Input / Decision alphabet

- Status: accepted
- Date: 2026-05-17
- Deciders: @emacsway

## Context

The execution_management BC slices a trader's intent into
broker-bound placements. Six concrete strategies are landed at
once — Immediate, TWAP, VWAP, POV, Iceberg, Implementation
Shortfall (Almgren-Chriss) — because confronting the abstraction
with genuinely different trigger surfaces (one-shot,
time-driven, volume-driven, fill-driven, market-data-adaptive)
is the cheapest way to discover the right shape *before* it
carries production weight. A single strategy would let the
abstraction silently optimise for one trigger surface and ship
a hidden mismatch.

The OrderTicket aggregate owns the global invariants
(`Σ filled ≤ total_quantity`, terminal absorbtion of late
events, no submits in `Cancelling` / terminal states). The
strategy's job is local: decide *what to do next* in response
to inputs from the world, without touching aggregate state.

## Decision

### Common alphabet

Every strategy reads from a single closed `Input.t` union and
writes a single closed `Decision.t` record. Inputs name *what
happened in the world*:

```
type Input.t =
  | Tick of { now : int64 }
  | Volume_bar of { bar : Volume_bar.t }
  | Price_quote of { quote : Market_data_quote.t }
  | Placement_acknowledged of { placement_id : Placement_id.t }
  | Placement_filled of { placement_id : Placement_id.t;
                          fill : Fill_record.t }
  | Placement_rejected of { placement_id : Placement_id.t;
                            reason : string }
  | Placement_unreachable of { placement_id : Placement_id.t }
  | Placement_cancelled of { placement_id : Placement_id.t }
```

Decisions name *what the strategy proposes*:

```
type Decision.t = {
  submit : submit_request list;
  cancel : Placement_id.t list;
  terminal : Continue | Completed | Failed of string;
}
```

The strategy **proposes**; the aggregate **disposes**. Every
`submit_request` becomes a `Placement` only after the
aggregate's invariant checks pass.

### Strategy.t — closed variant

```
type Strategy.t =
  | Immediate of Immediate.state
  | Twap of Twap.state
  | Vwap of Vwap.state
  | Pov of Pov.state
  | Iceberg of Iceberg.state
  | Implementation_shortfall of Implementation_shortfall.state
```

Each `state` is opaque to the dispatcher; only the per-strategy
module sees its internals. Adding a seventh strategy is a
compiler-guided refactor — every `match` site fails until the
new constructor is handled.

### First-class modules rejected

A first-class-module dispatcher was considered and rejected on
four grounds:

1. **The strategy set is bounded and known at compile time.**
   Open extensibility is a non-goal.
2. **State must be serialisable.** A future durable ticket store
   has to persist `Strategy.t`. Sum-type cases serialise
   trivially; existential package types do not.
3. **Why3 has no first-class-module story.** The strategies
   carry boundary-condition proofs (TWAP slice arithmetic,
   Iceberg `visible ≤ remaining`, IS trajectory monotonicity);
   keeping them in plain sum types preserves the proof path.
4. **Exhaustiveness is the enforcement mechanism.** A closed
   variant makes "did we handle the new strategy in every site"
   a compile-time question, not a runtime one.

### Disabled adapter for deferred feeds

VWAP and POV need a volume feed; Implementation Shortfall needs
market data. The infrastructure adapters are deferred. They land
as `Disabled_volume_feed` / `Disabled_market_data` — adapters
that register and never emit. This is deliberate: a strategy
that depends on a feed which never publishes is **observably
blocked**, not silently degraded to Immediate. The disabled
state surfaces in the strategy's `Decision.t` (no submits) and
in operator queries.

## Boundary-of-Why3 scope

Per-strategy formal proofs cover boundary conditions:

- All strategies: `Σ submitted_quantities ≤ total`, slice
  quantities non-negative, termination.
- TWAP: integer-division residue lands on the last slice;
  `Σ slice_qty = total`.
- Iceberg: `visible_qty ≤ remaining_qty` at every step.
- Implementation Shortfall: `Σ trajectory = total`, monotone
  decrease, termination.

The Almgren-Chriss closed-form mathematics itself is treated
as gospel-annotated and exercised by property tests on synthetic
price walks — full proof of optimality is out of scope.

## Consequences

**Easier:**

- Adding a strategy is a compiler-guided refactor with one
  obvious place to add the case.
- Strategy state lives in the same memory model as the rest of
  the aggregate — persistence, snapshots, and tests all see
  plain values.
- The Input/Decision alphabet is the contract that lets the
  aggregate operate generically over strategies without
  pattern-matching on which one is active.

**Harder:**

- A seventh trigger surface (e.g., "news event") would extend
  `Input.t` and force every strategy module to acknowledge the
  case — even strategies that ignore it. This is the cost of
  exhaustiveness and is paid back at every other site.

**To watch for:**

- If any strategy ever needs a *private* extension to
  `Decision.t` (a field the aggregate must not see), the
  abstraction has broken and either `Decision.t` grows or the
  strategy moves to a sibling layer. The PR2 checkpoint
  (validate before building the aggregate on top) caught zero
  such extensions — six strategies fit the shared shape.

## References

- ADR 0006 — Per-aggregate domain layout (the directory shape
  that hosts `strategies/`).
- ADR 0013 — Clock injection (strategies take `~now` as an
  argument; TWAP / VWAP / IS scheduling determinism in backtest
  depends on it).
- ADR 0017 — OrderTicket aggregate (the consumer of this
  abstraction).
