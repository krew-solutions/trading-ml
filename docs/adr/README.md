# Architecture Decision Records

This directory holds **ADRs** — short, dated documents capturing
significant architectural decisions, the alternatives considered,
and the rationale for the choice.

The format follows Michael Nygard's [original
proposal](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions):
numbered, markdown, structured. Each ADR is immutable once merged
— supersede with a new ADR rather than editing.

## Index

| № | Title | Status | Date |
|---|---|---|---|
| [0001](0001-hexagonal-architecture.md) | Hexagonal architecture | Accepted | 2026-04-15 |
| [0002](0002-mli-guardrails.md) | `.mli` files for every domain module | Accepted | 2026-04-16 |
| [0003](0003-stream-over-frp.md) | Custom streams on `Seq.t` over FRP libraries | Accepted | 2026-04-17 |
| [0004](0004-pipeline-unification.md) | One `Pipeline.run` for Backtest and Live | Accepted | 2026-04-17 |
| [0005](0005-reservations-ledger.md) | Reservations ledger for order lifecycle | Accepted | 2026-04-18 |
| [0006](0006-domain-layer-per-aggregate-layout.md) | Per-aggregate domain layout | Accepted | 2026-04-28 |
| [0007](0007-decimal-as-string-in-dto.md) | Decimal as canonical string in DTOs | Accepted | 2026-05-01 |
| [0008](0008-margin-model-for-short-selling.md) | Margin model for short selling | Accepted | 2026-05-02 |
| [0009](0009-portfolio-management-bounded-context.md) | Portfolio Management bounded context | Accepted | 2026-05-03 |
| [0010](0010-alpha-mind-vs-bracket-exit-projection.md) | Alpha-mind vs bracket-exit projection on the strategy → PM contract | Accepted | 2026-05-05 |
| [0011](0011-risk-evacuation-and-place-order-saga.md) | Risk evacuation from Strategy; pre_trade_risk and execution_management BCs; Place_order saga | Accepted | 2026-05-08 |
| [0012](0012-paper-broker-bounded-context.md) | Paper broker as a bounded context; matching engine in Why3-verified domain | Accepted | 2026-05-14 |
| [0013](0013-clock-injection.md) | Time injection: Domain takes timestamps, Application reads from injected Clock | Accepted | 2026-05-14 |
| [0014](0014-atd-wire-contracts.md) | ATD-generated wire contracts for cross-BC DTOs | Accepted | 2026-05-16 |
| [0015](0015-broker-domain-model.md) | Broker domain model | Accepted | 2026-05-16 |
| [0016](0016-execution-strategy-abstraction.md) | Execution-strategy abstraction (closed variant) | Accepted | 2026-05-17 |
| [0017](0017-order-ticket-aggregate-and-oms-ems-layering.md) | OrderTicket aggregate + OMS/EMS layering inside execution_management | Accepted | 2026-05-17 |
| [0018](0018-in-memory-ticket-store-transitional-persistence.md) | In-memory ticket store as transitional persistence | Accepted | 2026-05-17 |
| [0019](0019-execution-directive-provenance.md) | execution_directive provenance: PM authors, PTR passes through, EMS consumes | Accepted | 2026-05-17 |
| [0020](0020-order-management-bounded-context.md) | Order_management as a separate Bounded Context | Accepted | 2026-05-17 |
| [0021](0021-intake-gates-belong-to-pre-trade-risk.md) | Intake gates (kill_switch, rate_limit) belong to pre_trade_risk | Accepted | 2026-05-17 |
| [0022](0022-saga-owns-account-commit-and-release.md) | Order_process_manager owns Account commit and release | Accepted | 2026-05-17 |
| [0023](0023-broker-bar-feed-into-em-ports.md) | Broker bar feed into execution_management — one subscriber, two ports | Accepted | 2026-05-19 |
| [0024](0024-equity-anchored-sizing-with-explicit-risk-config.md) | Equity-anchored sizing with explicit Risk_config | Accepted | 2026-05-19 |
| [0025](0025-volatility-target-sizing.md) | Volatility-target sizing as the first vol-aware policy | Accepted | 2026-05-19 |
| [0026](0026-bar-stream-multi-timeframe-routing.md) | Bar streams as first-class subscriptions; multi-timeframe routing through domain BCs | Proposed | 2026-05-20 |
| [0027](0027-kalman-pair-mean-reversion.md) | Adaptive-β pair mean reversion as a sibling policy | Accepted | 2026-05-24 |
| [0028](0028-account-progressive-reservation-drawdown.md) | Progressive reservation drawdown in Account | Superseded by 0029 | 2026-05-24 |
| [0029](0029-single-terminal-commit-and-per-trade-execution.md) | Single terminal commit: per-trade Trade_executed, one fill_recorded at ticket close | Accepted | 2026-05-25 |

## Template

Copy this for new ADRs:

```markdown
# NNNN. Title

**Status**: Proposed | Accepted | Deprecated | Superseded by NNNN
**Date**: YYYY-MM-DD

## Context

What is the situation that prompts this decision? What forces
are at play?

## Decision

What we're going to do.

## Alternatives considered

Other options we looked at, with honest trade-offs.

## Consequences

What becomes easier, what becomes harder, what we'll have to
watch for.

## References

Links to commits, discussions, external sources.
```

## Numbering

Four-digit left-padded, monotonically increasing. Don't renumber.
If an ADR is superseded, the new one references it explicitly and
the old one's status becomes `Superseded by NNNN`.

## When to write an ADR

Write one when the decision:
- Would be hard to revisit (affects API shape, dependencies,
  module boundaries).
- Trades off between plausible alternatives in a non-obvious way.
- Encoded reasoning future readers would want to understand
  without re-deriving from git history.

Skip for:
- Pure implementation choices reversible with a local refactor.
- Conventions covered by a style guide or lint rule.
- Individual bug fixes.

Rule of thumb: if explaining the decision would take a
multi-paragraph git commit message, it probably deserves an ADR.
