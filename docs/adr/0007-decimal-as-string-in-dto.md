# 0007. Decimal as canonical string in DTOs

**Status**: Accepted
**Date**: 2026-05-01

## Context

The domain layer represents money (prices, quantities, cash, fees,
PnL) as `Core.Decimal.t` — a fixed-point fixed-scale (10⁸) integer
type whose semantics are formally specified in `decimal.mlw` and
discharged via Why3. This is load-bearing for the project's
reference-application thesis: the verified Decimal arithmetic
underpins every reservation, fee calculation, and position update.

DTOs (CQRS commands, integration events, read-model view models)
must carry these monetary values across:

1. **The internal message bus** (in-memory today, Kafka tomorrow) —
   serialised JSON via `[@@deriving yojson]`.
2. **The HTTP API** consumed by the Angular UI and the CLI.
3. **External broker adapters** (Finam REST, BCS REST, future ones).

DTOs be *serialisable and not contain ValueObjects* — so the question is
**which primitive form** carries a `Decimal` across these boundaries.

Until this ADR the answer was inconsistent:

- `Reserve_command.{quantity, price}` were `float`.
- `Submit_order_command.quantity` was `float`.
- `Amount_reserved_integration_event.{quantity, price, reserved_cash}`
  were `float`.
- `Order_kind_view_model.{price, stop_price, limit_price}` were
  `float option`.
- `Order_view_model.{quantity, filled, remaining}` were `float`.
- Every `of_domain` projection went through `Decimal.to_float`;
  every workflow input went through `Decimal.of_float` (which
  `decimal.mli` flags as **"Lossy; use only at system boundaries"**).

The result was a precision leak that bypassed the formal
verification: a wire string `"100.10"` parsed at the HTTP edge into
an exact `Decimal`, was projected back out through `to_float`
(IEEE 754 round-off), bus-serialised as a JSON `Float`, and
re-entered the workflow via `of_float` (more round-off). The
verified Why3 invariants held only inside a window the wire format
arguably never let real values reach intact.

The Finam REST schema (their order endpoint, accounts/portfolio
endpoint, etc.) independently uses Google's
[`google.type.Decimal`][google-decimal] convention — a wrapper
object `{ "value": "<decimal-string>" }` — for the same reasons:
gRPC well-known types, AIP-128, BigDecimal/decimal.Decimal on the
client side. So the industry pattern was already in front of us.

[google-decimal]: https://github.com/googleapis/googleapis/blob/master/google/type/decimal.proto

## Decision

DTOs (commands, integration events, view models) carry Decimal
values as **canonical decimal strings** matching the OCaml
`Core.Decimal.to_string` output. Parsing in / out goes through
`Decimal.of_string` / `Decimal.to_string` — both lossless,
bit-exact round-trip — and never through `of_float` / `to_float`.

The internal wire shape is a **bare JSON string** (`"100.10"`).
External broker adapters that follow `google.type.Decimal` (Finam)
add their own `{ "value": "..." }` wrapper on the way out via
`Acl_common.Decimal_wire.yojson_of_t_wrapped` — the wrapper lives
**only** at the ACL boundary, not in our internal message format.

Concretely:

| DTO field shape  | Inside the system            | At Finam REST boundary       |
|------------------|------------------------------|------------------------------|
| Reading          | `string` (bare)              | `{ "value": string }`        |
| Writing          | `string` (bare)              | `{ "value": string }`        |
| OCaml type       | `string`                     | `Decimal_wire.t` (= `string`)|
| Parser           | `Decimal.of_string`          | `Acl_common.decimal_of_json` |
| Emitter          | `Decimal.to_string`          | `Decimal_wire.yojson_of_t_wrapped` |

The bare-string internal form is intentional: it minimises wire
noise on every event/command in the bus (one `"100.10"` vs.
`{"value":"100.10"}`); it keeps `[@@deriving yojson]` derivation
trivial; and the wrapping that Finam's API requires belongs in the
ACL anyway. If a future internal bus consumer (audit, downstream
service) wants the AIP-128 self-describing wrapper, the
projection lives in their adapter, not in our shared shape.

UI follows the same discipline. A `ui/src/app/decimal.ts` module
mirrors `Core.Decimal` (10⁸ scale, BigInt-backed, same parse rules,
same canonical string output). Wire-format DTOs in the Angular HTTP
layer use `string` for monetary fields; parsing and emission go
through this `Decimal` class. The single permitted lossy step is
`Decimal.toNumber()`, called explicitly at the chart-library
boundary where lightweight-charts requires a JS `number` — every
such call is grep-able from the codebase, making the precision-loss
sites auditable.

Float remains permitted for fields that are **not Decimal-derived
in the domain**: ratios (`Backtest.total_return`, `max_drawdown`),
strategy confidence (`Signal.strength`), workflow configuration
parameters (`slippage_buffer`, `fee_rate` — see "To watch for"
below), and timestamps. These are domain floats, not money.

## Alternatives considered

### `float` (the prior state)

The wire format every broker REST originally seems to suggest, and
what the codebase started with. Rejected because of the round-trip
precision leak described in *Context*: every DTO crossing erased
the formally-verified Decimal semantics that the rest of the
system depends on. Wlaschin (DMMF) and Vernon (IDDD) both call
this out as an anti-pattern for monetary values; we were paying
for formal verification we then discarded at the wire boundary.

### Wrapped form `{ "value": "<string>" }` everywhere (AIP-128 / google.type.Decimal)

The Finam REST shape, also used by gRPC well-known types. Considered
because it would make our internal DTOs structurally identical to
the external format, eliminating one translation step in the ACL.

Rejected for internal use: the wrapper is a `protobuf` artefact
(every scalar in `protobuf` becomes a message), and we are not on
gRPC. Inside an in-memory or Kafka bus the wrapper costs ~10
extra bytes per field with no semantic benefit; the
`{ "value": ... }` shape adds nesting that downstream consumers
(SSE projector, audit) must unpeel for every field. The bare
string carries the same information without the ceremony, and the
ACL adapter for Finam adds the wrapper on its way out — a single
file (`broker/lib/infrastructure/acl/common/decimal_wire.ml`)
encapsulates the translation. If a future broker requires raw
strings (not wrapped), the same ACL pattern serves it without our
internal shape changing.

### Int64 with a per-field declared scale

What `Core.Decimal` itself uses internally (10⁸ scaled int64).
Considered because it's even more compact on the wire and
round-trip-trivial. Rejected because:

- JSON has no native int64; we'd need `string`-encoded int64 (e.g.
  `"10000000000"` for `100`) which is far less human-readable than
  `"100"`. Operators inspecting Kafka payloads or HTTP responses
  in dev tools have to decode the scale mentally.
- Different fields could in principle carry different scales (e.g.
  share price vs. crypto price); the canonical decimal string
  is self-describing in a way an int64-with-implicit-scale is not.
- The proto-style `{ value, scale }` envelope exists in the `acl`
  decoder tolerantly (`Acl_common.Decimal_wire.of_yojson_flex`)
  for upstream APIs that emit it, but is not chosen for our
  internal format.

### Internal type `Decimal.t` carried in DTOs (no projection)

Would skip the string round-trip entirely. Rejected because DTOs
must be JSON-serialisable per `[@@deriving yojson]`
needs a primitive — adding custom yojson converters for `Decimal.t`
would have re-introduced the same parse/emit functions we use
today, just hidden inside derived code rather than visible at
DTO field declarations. Visibility is the point: each DTO field
should make its precision contract obvious to a reader.

### Custom decimal library on the UI side (decimal.js / dnum / bignumber.js)

Considered for the Angular layer instead of writing
`ui/src/app/decimal.ts`. Rejected because:

- A library brings its own model of decimal (configurable precision,
  rounding modes); round-trip with our 10⁸-scale `Core.Decimal`
  would hold "in practice" but not by construction.
- decimal.js is ~33 KB minified, decimal.js-light ~9 KB; our needs
  are minimal (parse / format / very rare arithmetic), and ~80 LOC
  on top of `BigInt` matches `Core.Decimal` semantics 1:1, with a
  unit-test file pinning that correspondence.
- Reference-application ethos — a small bespoke module
  with property tests pinning it to the OCaml side is more
  pedagogical than a "trust the npm dep" choice.

If UI-side arithmetic grows beyond what the bespoke module
naturally supports (display formatting + occasional Δ / sums), the
decision can be revisited; switching to `decimal.js` would be a
local change to `ui/src/app/decimal.ts`'s implementation, since the
public surface mirrors `Core.Decimal` not the library.

## Consequences

**Easier**:

- Bit-exact round-trip across every boundary: HTTP ingress, command
  bus, event bus, view-model projection, HTTP egress, UI parsing.
  No lossy `of_float` / `to_float` step on the path of any monetary
  value.
- The formally-verified `Decimal` semantics now actually hold for
  values that real users send and receive — Why3 proofs over
  `decimal.mlw` are no longer islands surrounded by float noise.
- Symmetry with `google.type.Decimal` (Finam, future gRPC brokers,
  most modern trading APIs): the only difference at the ACL is
  whether to wrap in `{ "value": ... }` — handled in
  `Decimal_wire.yojson_of_t_wrapped`, ~one line per outbound site.
- Each DTO field's wire contract is visible in the type
  declaration; no hidden lossy conversion in the derived JSON
  codec.

**Harder**:

- Decimal strings are slightly larger than JSON `Float` on the
  wire (`"100.1"` vs `100.1`). Negligible at the volumes we care
  about; if it ever matters at a hot consumer, a binary protocol
  is the answer, not float-in-JSON.
- Workflow code that needs to do arithmetic on a wire-DTO field
  must call `Decimal.of_string` first (we already do this in
  `Reserve_command_workflow`, `Submit_order_command_handler`).
  This is by design — the parse step is the moment the value
  becomes a verified `Decimal`; before that, it's just a string.
- Front-end consumers (Angular, CLI) must agree that monetary
  fields are decimal strings. The `ui/src/app/decimal.ts` module
  enforces this on the Angular side; the `bin/main.ml` CLI was
  updated to send decimal strings via `Decimal.to_string` and
  parse them via `to_string` reads.

**To watch for**:

- The BCS REST adapter still serialises prices as JSON `Float`
  (`broker/lib/infrastructure/acl/bcs/rest.ml::create_order` and
  similar), because BCS's wire format demands raw numbers, not
  `google.type.Decimal` wrappers. This is a constraint of their
  API, not our choice — the lossy step is contained in the
  outermost adapter line and is the only place inside our codebase
  where a `Decimal` becomes a `Float` on outbound. If BCS ever
  exposes a string/decimal representation, switch the three
  `Decimal.to_float` lines in `rest.ml` to
  `Decimal_wire.yojson_of_t` (bare string) or
  `yojson_of_t_wrapped`.
- Workflow configuration parameters `slippage_buffer` and
  `fee_rate` (in `Reserve_command_handler` /
  `Reserve_command_workflow`) are still typed as `float`. These
  are not DTO fields — they're injected from the composition root
  in `bin/main.ml` (`~slippage_buffer:0.005 ~fee_rate:0.0005`).
  But they end up in `Decimal.mul` calls inside
  `account/lib/domain/portfolio/reservation/reservation.ml` via
  `Decimal.of_float` — the same lossy conversion this ADR aims to
  eliminate at DTO level. A follow-up ADR (or amendment to this
  one) should change them to `Decimal.t` and parse from
  decimal-string config at startup. Tracked separately because the
  scope here is DTOs, not workflow configuration.
- The BCS adapter additionally truncates `Decimal.t -> int` (via
  `int_of_float (Decimal.to_float quantity)`) because BCS's
  `orderQuantity` is integer (MOEX equities trade in integer lots).
  Fractional `quantity` from upstream would be silently truncated,
  causing a reservation/fill mismatch. This is a known bug-class,
  unrelated to the wire-format change, but worth a separate
  validation pass that rejects fractional `quantity` at the BCS
  adapter boundary.

## References

- `strategy/lib/domain/core/decimal.mli` — `of_float` is flagged
  *"Lossy; use only at system boundaries"*; this ADR confines the
  boundary to BCS-adapter outbound and form-input `<input
  type="number">`.
- `strategy/lib/domain/core/decimal.mlw` — Why3 specification of
  the same operations.
- Google AIP-128 / `google.type.Decimal` — industry pattern for
  decimal-as-string with optional `{value, scale}` envelope:
  <https://github.com/googleapis/googleapis/blob/master/google/type/decimal.proto>.
- Finam OpenAPI for `POST /v1/accounts/{account_id}/orders` —
  `quantity`, `limit_price`, `stop_price` as `{ "value": "..." }`.
- Wlaschin, *Domain Modeling Made Functional*, ch. 11 ("Serialization")
  — DTO-as-strings for precision-critical fields.
- Vernon, *Implementing Domain-Driven Design*, ch. 6 ("Value Objects")
  — money in DDD as a precision-aware ValueObject, never `float`.
- ADR 0002 — `.mli` guardrails (the wire-string discipline is
  enforced compiler-side via the same boundary mechanism).
