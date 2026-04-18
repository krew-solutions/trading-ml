# 0002. `.mli` files for every domain module

**Status**: Accepted
**Date**: 2026-04-16

## Context

OCaml allows a module without an `.mli` interface file to export
everything defined in its `.ml` — all types, values, including
implementation details. Early iterations of this project had
wire-format conversion functions (`status_of_wire`, `kind_to_wire`)
living in `lib/domain/core/order.ml`, visible to anyone who
imported `Order`. When we started adding ACL adapters for
individual brokers, these functions became a quiet coupling
point: the domain type had Finam-shaped converters attached.

The problem surfaced when BCS entered the picture. Its order
status enum is entirely different (numeric strings `"1"..."8"`
vs. Finam's `ORDER_STATUS_*`). We couldn't have both sets of
converters in `Order` without namespace-prefixing them, which
was ugly and still let them leak. The right answer was: those
converters don't belong in the domain at all; they're ACL
translators.

But once we'd moved them out, nothing prevented the same mistake
from recurring. A future contributor could add an
`order_from_grpc_enum` helper to `order.ml` and it would just
silently become part of the public API.

## Decision

**Every `.ml` file in `lib/domain/` has a matching `.mli` file.**
The interface is curated: it exposes the types, constructors,
observers, and predicates the domain actually wants downstream
code to see. Implementation details, wire-format helpers, or
internal transformations live only in `.ml`.

Enforcement is structural:

- `dune` auto-detects `.mli` files and uses them as the module's
  public signature. Anything not in `.mli` is module-private.
- When a domain module grows something that *could* be exposed
  but *shouldn't* (like a wire-format helper), the author must
  decide: put it in the `.mli` (visible everywhere) or leave it
  out (module-private).
- Code review catches drift: adding a type to the `.mli` is a
  deliberate, visible act.

## Alternatives considered

### Relying on naming conventions

"Just don't put wire converters in the domain." Works until it
doesn't. We'd already seen it fail once.

### Strict sub-module isolation

Put wire converters inside a nested module
(`module Wire : ... end`) within the domain module. Sub-modules
are still exported; the only way to hide them without an `.mli`
is to make them module-private via `let _ = ...`, which is even
uglier.

### `.mli` only for "public" libraries, `.ml`-only for "internal"

Creates two tiers of modules with different rules. The line
between "public" and "internal" is subjective and the rule
erodes. Uniform policy is easier to enforce.

## Consequences

**Easier**:

- Module interfaces are documented by construction. The `.mli`
  is the canonical place to add doc comments; `odoc` generates
  HTML from them.
- Refactors of `.ml` internals don't break callers if the `.mli`
  is preserved. This gives us confidence to clean up
  implementations without ripple effects.
- Compile-time enforcement of layer boundaries: the ACL adapter
  can `open Core.Order` and see the domain type, but cannot
  access domain-internal helpers because they're not in the
  `.mli`.

**Harder**:

- Writing a new domain module means writing two files, not one.
  The `.mli` duplicates type declarations (`type t = int64` in
  both `decimal.ml` and `decimal.mli`). Minor friction.
- Private records (`type t = private { ... }`) require care —
  the field names are still visible in the `.mli` for reading,
  but construction goes through a smart constructor. Standard
  OCaml pattern, but new contributors trip on it.

**To watch for**:

- Temptation to "just expose this one thing temporarily". That's
  how the wire converters leaked last time. If something needs
  to be shared between two modules but not with the rest of the
  world, consider a private sub-module or a shared internal
  helper library in the same layer.
- `.mli` documentation drift: comments in the `.mli` are the
  docs that readers see. Keep them truthful even when the
  implementation shifts.

## Consequences observed since adoption

After adding `.mli` to all 35 domain modules (the second
renovation), we caught three latent leaks: wire helpers, a
mutable internal cache, and a raw `Yojson` value returned from
what should have been a pure decoder. None of these would have
been caught by tests — the tests used the "correct" parts of
the API and didn't accidentally invoke the leaked ones.

## References

- [Architecture overview](../architecture/overview.md)
- [Domain model](../architecture/domain-model.md)
