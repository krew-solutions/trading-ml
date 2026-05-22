# 0020. Order_management as a separate Bounded Context

- Status: accepted
- Date: 2026-05-17
- Deciders: @emacsway

## Context

ADR 0017 introduced an OMS / EMS split *inside* the
`execution_management` BC: `Order_process_manager` (the saga that
orchestrated cash reservation + handoff) lived as an application-
layer process manager alongside the OrderTicket aggregate and the
six execution strategies. The hand-off between them was an
in-process function-port — a `Dispatch_open_ticket` saga command
routed by the factory closure into
`Open_order_ticket_command_workflow.execute`, justified at the
time by "a model inside a BC cannot send a Command to itself
over its own bus."

That justification was correct but the framing was wrong: the OMS
and EMS layers don't share *anything* domain-level. The saga
owns reservation-cycle state (correlation_id → reservation_id);
the aggregate owns execution state (ticket → placements → fills).
They communicate through a single command and produce different
outbound IE sets. Keeping them in the same BC was an artifact of
how the saga grew historically, not of any shared invariant.

Step 3 in the trajectory (extending the saga to drive
`Commit_fill_command` / `Release_command` against Account on
OrderTicket lifecycle events) further amplifies the mismatch.
A saga that orchestrates *both* Account-side reservation lifecycle
*and* observes EMS-side aggregate events naturally sits between
those two BCs, not inside one of them.

## Decision

Extract `Order_process_manager` into a new BC `order_management`.
After extraction:

- **`order_management`** — the OMS layer. Hosts the saga, its
  inbound IE mirrors (PTR's `Trade_intent_approved`, Account's
  `Amount_reserved` / `Reservation_rejected`), and the saga's
  outbound wire commands (`Reserve_command` to Account,
  `Open_order_ticket_command` to EM). The saga is the only owner
  of cross-BC orchestration between PM/PTR, Account, and EM.

- **`execution_management`** — the EMS layer. Hosts the
  OrderTicket aggregate, the six execution strategies, the
  broker-IE ACL handlers, and the operator-facing query / cancel
  surfaces. Loses the saga and its inbound saga-feeding
  subscriptions. Gains a new bus subscription to its own
  `open-order-ticket-command` URI for the cross-BC command from
  OM.

```
PM   → Trade_intents_planned     → PTR
PTR  → Trade_intent_approved     → OM (saga starter)
OM   → Reserve_command           → Account
Account → Amount_reserved        → OM (saga advance to Done)
OM   → Open_order_ticket_command → EM (cross-BC wire command)
EM   → opens OrderTicket aggregate
EM   ↔ Broker (Submit / Cancel ↔ Order_accepted / Filled / Rejected / Unreachable / Cancelled)
EM   → Order_ticket_* IEs        → (telemetry consumers)
EM   → Release_command           → Account  (on terminal failed / cancelled — step 2 transitional; step 3 moves this to OM)
```

### Option A — wire command on the bus

`Open_order_ticket_command` becomes a real cross-BC wire command:
ATD contract at `shared/contracts/execution_management/commands/`,
atdgen-generated _t / _j on EM's side, hand-coded wire shape on
OM's outbound factory. The in-process function-port from ADR
0017 is *removed*; the command goes over the bus like every other
cross-BC command in the system.

The original rationale for the function port (the model
inside-a-BC-can't-self-command rule) no longer applies once the
saga lives in a separate BC. Cross-BC commands over the bus are
the orthodox pattern; this just brings the OMS→EMS handoff in
line with `Reserve_command`, `Submit_order_command`, and every
other cross-BC command in the project.

### Transitional gate placement

Kill_switch and rate_limit stay in `execution_management` *for
this step*. The factory now enforces them at `Open_order_ticket_command`
receipt: on a tripped gate, EM publishes
`Trade_submission_blocked` and `Release_command` (to undo the
Account-side reservation that already landed). The reservation
cycle is therefore wasted on tripped intents — accepted as a
short-lived transitional cost.

The longer-term home is `pre_trade_risk` (per the follow-up step
2.5): PTR already subscribes to `Reservation_filled`, its
`Risk_view` domain already maintains the equity invariant, and
it is the canonical pre-trade gate. The wasteful reservation
cycle disappears once the gate moves to PTR — PTR rejects the
assessment, no IE reaches OM, no reservation gets allocated.

### Saga scope unchanged in this step

Step 2 keeps the saga at its current scope:
`Awaiting_reservation → Done | Compensated`. Step 3 extends it
to subscribe to OrderTicket lifecycle events from EM (per-fill,
terminal) and emit `Commit_fill_command` / `Release_command` to
Account directly from the saga. After step 3, EM no longer
publishes `Release_command` itself — the saga becomes the single
Account-facing orchestrator.

## Why not a smaller change

Three alternatives were considered:

**Keep the saga in EM.** Rejected on the grounds that step 3
requires the saga to subscribe to OrderTicket events. Today's
in-process function port routes EM → OrderTicket; for step 3 we'd
need a *reverse* function port OrderTicket → saga, which would
mean two opposing in-process couplings between the OMS and EMS
layers. Two function ports in opposite directions is the moment
a BC split becomes inevitable; better to split now.

**Make the saga subscribe to bus IEs from inside EM.** Still
violates the project's "BC doesn't react to its own IEs" rule.
Pushing the saga into a separate BC removes the rule violation
by construction.

**Compose at the composition root via two function ports.** A
non-orthodox shape: would let the saga stay in OM (clean) and
EM stay separate (clean) but require `bin/main.ml` to wire two
direct function-call closures across BC boundaries. Plausible
in a single-process deployment; rejected because every other
cross-BC interaction in the system is bus-mediated and asymmetry
here would be surprising for future readers.

## Consequences

**Easier:**

- The OMS saga becomes a first-class BC with a clear remit: it
  owns the reservation-cycle orchestration across PM/PTR,
  Account, and EM.
- EM becomes a focused EMS-layer BC: aggregate, strategies,
  broker dialog. No intake plumbing.
- Step 3 (saga subscribes to OrderTicket events, dispatches
  Commit_fill / Release) becomes a natural extension of OM
  rather than a structural intrusion into EM.
- Step 2.5 (kill_switch / rate_limit → PTR) is unblocked: PTR
  becomes the single intake gate as originally intended in ADR
  0011.
- Cross-BC dependencies become explicit and bus-mediated end to
  end: no more "function port across BC boundaries" exceptions.

**Harder:**

- One more BC to maintain in `bin/main.ml` and the test matrix.
  Marginal, since the existing per-BC patterns are well-trodden.
- Transitional waste: tripped kill_switch / rate_limit causes a
  full Reserve → Release round-trip through Account. Resolved
  by step 2.5.

**To watch for:**

- The `Open_order_ticket_command` wire shape carries
  `reservation_id`, `correlation_id`, and the optional
  `execution_directive`. As the trader-intent surface evolves
  (richer routing hints, time-in-force at intent level, etc.),
  every addition must thread through *three* sites: PM trade_intent
  view model, PTR assess command + approved IE, OM saga payload +
  Dispatch_open_ticket + the wire command, EM handler.
  Each is generated independently per ADR 0001's BC-independence
  rule. Drift between sites is possible — covered today by the
  `execution_directive_parse_test.ml` round-trip test; expand
  coverage as the shape grows.

## References

- ADR 0001 — Hexagonal Architecture (the BC-independence rule
  this ADR honours).
- ADR 0011 — Risk-evacuation and Place-Order saga (the original
  saga that this ADR extracts).
- ADR 0017 — OrderTicket aggregate + OMS/EMS layering (the
  in-BC layering this ADR supersedes the boundary of).
- ADR 0019 — execution_directive provenance (the field threaded
  through the new wire command).
