# 0019. Execution directive originates at portfolio_management; pre_trade_risk passes through unchanged; execution_management consumes with Execution_policy fallback

- Status: accepted
- Date: 2026-05-17
- Deciders: @emacsway

## Context

An `execution_directive` answers the question **how** to
execute a trader intent (Immediate, TWAP, VWAP, POV, Iceberg,
Implementation Shortfall). The intent itself answers
**what** (instrument, side, quantity, book).

The strategic question is *who owns this choice*. Three
candidates were on the table at various points:

1. **portfolio_management** authors it as part of the trader
   intent. PM knows the strategic context (mean-reversion vs.
   momentum, urgency, expected alpha decay) — that context is
   exactly what selects the right strategy.
2. **pre_trade_risk** assigns it. PTR sees the gate context
   (risk view, current exposure) and could, in principle, pick
   a less aggressive strategy for a marginal intent.
3. **execution_management** picks it from a policy table. EM
   knows the venue and timing constraints (liquidity, session,
   volatility regime).

## Decision

**portfolio_management authors.
pre_trade_risk passes through.
execution_management consumes — with an internal fallback when
absent.**

This mirrors FIX wire semantics: `HandlInst` / `ExecInst` /
`AlgoStrategy` travel with the order from the originator and
are not modified by intermediate parties.

### Rationale: PTR is an approver, not an enricher

Pre-trade risk's contract is binary: **veto or pass**. A gate
that silently downgrades an Iceberg directive to Immediate
because exposure is high has rewritten the trader's instruction
without telling the trader. That is enrichment masquerading as
approval, and it makes the gate's decisions opaque.

If risk *should* affect execution strategy, that's a separate
upstream concern — the strategy layer can read the risk view
when forming the intent. The boundary stays clean.

### Rationale: EM cannot be the author

EM doesn't see the strategic context that motivated the trade.
Picking Implementation Shortfall vs. Iceberg requires knowing
whether the trader needs to minimise market impact
(longer-horizon alpha) or hide size (short-horizon mean
reversion). EM only sees one leg at a time.

### Rationale: a fallback is needed

The wire field is **optional**. The alpha / strategy layer that
will eventually author directives is a separate trajectory; the
legacy callers (today: every caller) emit intents without it.
The EMS-side ACL falls back to an internal
`Execution_policy.default` — currently `Immediate`. The fallback
is a domain value object so a future per-book / per-instrument
policy lands in one named place.

### Wire flow

```
portfolio_management
  Trade_intent_view_model { ..., execution_directive? }
    ↓
  Trade_intents_planned_integration_event
    ↓
pre_trade_risk (ACL handler)
  Assess_trade_intent_command { ..., execution_directive? }    ← carried through
    ↓
pre_trade_risk (workflow)
  Trade_intent_approved_integration_event { ..., execution_directive? }    ← echoed
    ↓
execution_management (ACL)
  Open_order_ticket_command { ..., directive? }    ← parsed in handler
    ↓                                                ↓ absent → Execution_policy.default
  OrderTicket.open_ticket ~directive
```

Each BC owns its own generated copy of the
`execution_directive_view_model` ATD shape; the contracts live
in the producing BC's `shared/contracts/<bc>/view_models/`
directory.

### Wire shape

```
type execution_directive_view_model = {
  kind   : string;             (* IMMEDIATE | TWAP | VWAP | POV |
                                  ICEBERG | IMPLEMENTATION_SHORTFALL *)
  params : string option;      (* JSON-object string. None for IMMEDIATE. *)
}
```

The opaque `params` blob keeps the cross-BC contract stable
across strategy-parameter changes. Each consumer that needs the
typed parameters parses the blob against its own schema. EM's
`Open_order_ticket_command_handler.parse_directive` is the
authoritative parser; it validates per-strategy invariants at
the wire / domain boundary so malformed payloads fail in the
handler, not in the aggregate.

## Scope

This ADR governs the **provenance** of the directive on the
wire and at the ACL boundary. It does NOT govern:

- **Per-strategy parameter schemas.** Those evolve under each
  strategy module's own contract.
- **The current authoring trajectory in PM.** PM's domain
  `Trade_intent` does not yet carry a directive field; the
  alpha / strategy layer that will set it is a separate
  initiative. PR7's contribution is to *unblock* that layer by
  threading the wire field through every intermediate hop.
- **Operator override of an in-flight strategy.** Today a
  ticket's strategy is fixed at open time. An operator-issued
  retarget is a future capability that would surface as a
  separate command.

## Consequences

**Easier:**

- The strategy choice rides on the trader's intent end to end.
  When the alpha layer starts authoring directives, no
  intermediate BC has to change.
- The gate's contract stays narrow (veto / pass), which keeps
  its decisions reviewable.
- EM owns one named fallback policy; changing the default is a
  one-line edit in `Execution_policy.default`.

**Harder:**

- Three BCs now carry an additional optional field with
  identical shape, each generated independently per ADR-0001's
  BC-independence rule. Drift between the three contracts is
  possible — the test suite catches it indirectly via
  end-to-end fixtures but not directly.
- The `params` blob is unstructured at the contract level. A
  malformed blob is a runtime failure at the EMS ACL, not a
  build-time failure. The parser's invariant checks are the
  enforcement; coverage tests live in the EMS unit suite.

**To watch for:**

- If a fourth BC ever needs the directive (e.g., a future
  compliance gate downstream of PTR), it should follow the
  same pattern: own its mirror, carry the field through, do
  not enrich.
- If `Execution_policy.default` ever becomes context-dependent
  (per-book, per-instrument, time-of-day), the policy
  function's signature grows but its location stays the same —
  one named domain VO.

## References

- ADR 0001 — Hexagonal Architecture and BC-independence rule
  (each BC owns its mirror).
- ADR 0014 — ATD wire contracts (the generation discipline this
  ADR rides on).
- ADR 0016 — Execution-strategy abstraction (what the directive
  selects).
- ADR 0017 — OrderTicket aggregate (the consumer of the
  resolved directive).
- FIX 5.0 SP2 — `HandlInst`, `ExecInst`, `AlgoStrategy`. The
  wire-semantic precedent: execution preferences are properties
  of the order from inception, not added by intermediate
  parties.
