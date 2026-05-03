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
