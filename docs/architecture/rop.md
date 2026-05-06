# Railway-Oriented Programming

The application layer composes command handlers and projections
through a small, accumulating `Result` type. The pattern is Scott
Wlaschin's *Railway-Oriented Programming* (ROP) — a two-track
control flow where success and failure run in parallel and a
single `let*` / `let+` binding picks which combinator the caller
wants.

This document covers:

- the `Rop.t` type and its non-stdlib invariant (errors as a list);
- when to use applicative versus monadic binding;
- how command handlers in this project encapsulate validation;
- the naming convention for the post-parse form.

It assumes familiarity with the layering rules from
[`hexagonal-architecture.md`](hexagonal-architecture.md). The
code lives in [`shared/lib/rop/`](../../shared/lib/rop/).

## The type

```ocaml
type ('a, 'err) t = ('a, 'err list) result
```

The Error branch always carries a non-empty list. This is the
only deviation from `Stdlib.Result` worth memorising: it lets
parallel branches concatenate their failures without one of them
having to "win" arbitrarily.

The pieces a workflow author uses daily:

| Operator | Semantics | When to use |
|---|---|---|
| `let* x = ...` | Monadic bind — short-circuits on first Error | Sequential pipeline; step N depends on step N−1 |
| `let+ x = ... and+ y = ... and+ z = ...` | Applicative — runs all branches, concatenates errors | Independent field validations; user should see every problem in one round-trip |
| `Rop.succeed x` | Lift a value onto the success track | |
| `Rop.fail e` | Lift a single error onto the failure track | |
| `Rop.of_result r` | Lift `Stdlib.Result` into ROP (singleton error list) | Wrapping an aggregate's `Result` return |

The full surface (with applicative `<*>`, `&&&`, `>=>`, etc.) is
in [`rop.mli`](../../shared/lib/rop/rop.mli).

## Two binding styles, one pipeline

Mix freely: most workflows validate applicatively (multiple
fields, all errors at once), then bind monadically into the next
step (one cannot fetch an order if the order id is malformed).

```ocaml
let validate (cmd : Reserve_command.t)
    : (validated_reserve_command, validation_error) Rop.t =
  let open Rop in
  let+ side = parse_side cmd.side
  and+ instrument = parse_instrument cmd.symbol
  and+ quantity = parse_quantity cmd.quantity
  and+ price = parse_price cmd.price in
  { side; instrument; quantity; price }
```

A command with bad symbol AND bad side AND non-positive quantity
returns three errors at once, not one per round-trip.

Within a single field-level helper, ordering matters when one
check depends on another:

```ocaml
let parse_positive_decimal ~bad_format ~not_positive raw =
  match try Some (Decimal.of_string raw) with _ -> None with
  | None -> Rop.fail (bad_format raw)
  | Some d ->
      if Decimal.is_positive d then Rop.succeed d
      else Rop.fail (not_positive raw)
```

Sequential by necessity: the positivity check has no meaning on
input that does not parse. **Sequential within a field, parallel
across fields.**

## Errors are typed unions, not strings

Every failure carries a typed variant.

```ocaml
type validation_error =
  | Invalid_symbol of string
  | Invalid_side of string
  | Invalid_quantity_format of string
  | Non_positive_quantity of string
  | Invalid_price_format of string
  | Non_positive_price of string
```

The variant is the source of truth. A `validation_error_to_string`
projection exists for the human-readable channel (the `reason`
field of a rejection integration event). HTTP, telemetry, and
test assertions pattern-match the variant, not the string.

This has a downstream consequence: integration events never
carry opaque exception messages or unstructured server logs.
The reason that reaches a subscriber comes from a single
application-layer projection of the typed error.

## Command handlers encapsulate validation

A command handler accepts the wire-format command and is
responsible for the entire single-command step:

1. parse the DTO into domain types (private `validate`);
2. invoke the aggregate;
3. return the resulting domain event or a typed failure.

```ocaml
val handle :
  portfolio:Account.Portfolio.t ref ->
  next_reservation_id:(unit -> int) ->
  slippage_buffer:Decimal.t ->
  fee_rate:Decimal.t ->
  Reserve_command.t ->
  (Account.Portfolio.Events.Amount_reserved.t, handle_error) Rop.t
```

`validate` is **not** exported. There is no compositional reason
to expose it: a CQRS command is bound to exactly one handler in
exactly one workflow, and after parse there is one substantive
step (the aggregate call). Wlaschin's
`validateOrder >=> priceOrder >=> acknowledgeOrder >=> createEvents`
splits in his order-taking example because each step is itself
a business operation worth composing or reusing. Reserving cash
is one operation; nothing to compose `validate` with.

Domain-event handlers are different: a single domain event can
have multiple subscribers across different workflows (DIP), so
they are extracted into their own modules. Commands lack that
property.

## Failure track carries enough context for projections

`handle_error` is a sum of two failure modes:

```ocaml
type handle_error =
  | Validation of validation_error
  | Reservation of {
      attempted : validated_reserve_command;
      error : Account.Portfolio.reservation_error;
    }
```

The discriminator matters because the workflow projects the two
modes differently:

- `Validation` — the wire format never reached the aggregate;
  there is no business "rejection" to broadcast. Surfaces only
  through the `Rop.t` tail. Treated as a contract violation by
  the caller.
- `Reservation` — a well-formed attempt was rejected by the
  aggregate invariant (`Insufficient_cash`, `Insufficient_qty`).
  The workflow projects to
  `Reservation_rejected_integration_event` using the
  `attempted` record to populate side / instrument / quantity,
  and the typed error to populate the `reason` string.

The `attempted` payload is the only reason the validated-form
record is in the handler's `.mli`: the workflow needs to read
its fields when building the rejection event. A handler whose
flow has no failure-side integration event omits the payload.
Compare `Release_command_handler`:

```ocaml
type handle_error =
  | Validation of validation_error
  | Release of Account.Portfolio.release_error
```

No `attempted` record because there is no public release-rejected
integration event today.

## Naming

| Role | Name in this codebase | Rationale |
|---|---|---|
| Wire-format DTO (the public CQRS contract) | `Reserve_command.t` | A command is a public contract; an "unvalidated" prefix would leak an implementation detail of the recipient into the contract's name. The fact that the type carries strings is sufficient signal. |
| Post-parse domain-typed form | `validated_reserve_command` | Wlaschin's `ValidatedX`: syntax has been parsed into domain types, but aggregate invariants have not yet been checked. |
| Parse function (private) | `validate` | Wlaschin's `validateOrder`. |
| Error variant | `validation_error` | Wlaschin's `ValidationError`. |
| Integration event on success | `Amount_reserved_integration_event.t` | Past-tense fact; integration-event suffix disambiguates from the domain event of the same name. |

We do not use Wlaschin's `Unvalidated*` prefix. In *Domain
Modeling Made Functional* the input to `validateOrder` is
`UnvalidatedOrder`; the prefix communicates "this is the input
shape before validation". In our project the wire-format DTO
is a CQRS command — already a labelled public contract — and
prefixing its module name with `Unvalidated` would describe an
internal phase of its consumer leaking into the contract's
identity. The contract is what it is; "unvalidated" is private
to the handler that has not yet run.

## Workflow shape

The workflow returns the handler's `handle_error` directly; it
does not wrap it in a workflow-local error sum.

```ocaml
val execute :
  portfolio:Account.Portfolio.t ref ->
  next_reservation_id:(unit -> int) ->
  slippage_buffer:Decimal.t ->
  fee_rate:Decimal.t ->
  publish_amount_reserved:(Amount_reserved.t -> unit) ->
  publish_reservation_rejected:(Reservation_rejected.t -> unit) ->
  Reserve_command.t ->
  (unit, Reserve_command_handler.handle_error) Rop.t
```

The body is one match: success dispatches to the success-side
projection (`publish_amount_reserved`), failure iterates over
the error list and selectively projects `Reservation { ... }`
to the rejection integration event while ignoring `Validation`
(see above for why).

## When to short-circuit versus accumulate

Two failure modes coexist in the same `handle`:

- field-level parse failures from independent inputs —
  accumulate with `let+ / and+`;
- aggregate invariant failures that can only be checked once
  parse has produced domain types — short-circuit; the
  aggregate call is reached only on `Ok` of `validate`.

The two are distinguished in the failure track via the
`handle_error` sum, never flattened into one list. A response
that mixed "your symbol was invalid" with "you have insufficient
cash for this symbol" would be incoherent — the second message
presumes the first did not happen.

## See also

- [`hexagonal-architecture.md`](hexagonal-architecture.md) —
  where the ROP pieces fit in the application layer.
- Wlaschin, *Domain Modeling Made Functional* (Pragmatic
  Bookshelf, 2018), chapters 6–10 — the order-taking pipeline
  that motivates the two-track style.
- Wlaschin, *Railway Oriented Programming* —
  [`fsharpforfunandprofit.com/rop`](https://fsharpforfunandprofit.com/rop/)
  — the original presentation of the metaphor.
