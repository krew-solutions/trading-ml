# 0033. Finam gRPC broker ACL adapter

**Status**: Accepted
**Date**: 2026-06-04

## Context

Finam exposes the same Trade API over three transports — REST, WebSocket,
and gRPC — all generated from one set of `.proto` contracts (the REST surface
is the grpc-gateway projection of those protos). The existing
`broker/lib/infrastructure/acl/finam/` adapter speaks REST (+ WS, with a REST
poller for the spot tape). We want a second, fully self-contained adapter that
speaks **only gRPC**, both to exercise the binary/streaming transport and
because gRPC's native server-streaming is a better fit for the live feed than
the WS-stub-plus-REST-poll compromise the REST adapter is forced into.

The broker domain model (ADR 0015) already fixes the contract: every venue is
reached through the `Broker.S` port in the BC's uniform `Order` vocabulary,
with all protocol specifics below the ACL boundary. So this is a new adapter
under `broker/lib/infrastructure/acl/finam_grpc/`, not a change to any shared
type, and it is **independent of** the REST `finam` adapter — no module is
imported across the two (the placement-handle store is duplicated, per the
"each adapter owns its venue-identity store" rule).

## Decision

Implement `Finam_grpc.*` as a standalone adapter whose only outward dependency
is the Finam gRPC endpoint (`api.finam.ru:443`, TLS, ALPN `h2`). Module layout:

- `proto/` — vendored `.proto` subset + a dune rule that runs `protoc` with the
  `ocaml-protoc-plugin` driver at build time, producing the `finam_grpc_proto`
  library.
- `eio_gluten` — the HTTP/2 runtime driver (see workaround below).
- `channel` — gRPC-over-HTTP/2-over-TLS transport: connect, unary call,
  server-streaming call, status/trailers handling, message framing.
- `conv`, `order_dto` — wire ⇄ domain translation over the generated types.
- `config`, `client` — endpoint config; the single seam exposing the Finam RPCs
  (unary: bars, orders, venues, account trades; streaming: bars, public tape,
  own fills) with a JWT cache.
- `stream_runner` — reconnecting fiber for one server-stream.
- `placement_handle_store`, `finam_grpc_broker` — venue-identity store and the
  `Broker.S` implementation.

Five points are deliberate departures worth recording.

### 1. Toolchain: build-time codegen via system `protoc` + `ocaml-protoc-plugin`

The protobuf bindings are generated at build time by a dune rule, not checked
in. This requires two build-time tools: the `protoc` compiler on `PATH`, and
the `ocaml-protoc-plugin` driver (`protoc-gen-ocaml`, resolved from the opam
switch via `%{bin:...}`). See `docs/howto/finam-grpc-toolchain.md` for the
exact install. The plugin parameter `prefix_output_with_package=false` is left
default; messages map to nested modules under `Grpc.Tradeapi.V1.*` and
single-field messages collapse to their bare value (so `google.type.Decimal`
is a `string` and a single-`repeated`-field response is a bare list).

### 2. Vendored protos are stripped to the pure-gRPC contract

The public Finam `.proto` files import `google/api/annotations.proto` and the
grpc-gateway `openapiv2` options, and annotate every RPC with
`option (google.api.http)` / openapiv2 metadata. That tree exists only for the
REST transcoder and OpenAPI doc generation; it is irrelevant to gRPC codegen
and would drag in the descriptor/struct/openapiv2 extension protos (and a
filename collision: two different `annotations.proto`). We vendor a **stripped**
subset under `proto/`: the gateway/api imports and their `option (...)` blocks
are removed, leaving only the messages, enums, and services plus the small
`google.protobuf`/`google.type` deps actually referenced. Codegen is then
hermetic (`protoc -I .`), with no system protobuf include directory needed.

### 3. Transport: own the HTTP/2 runtime loop instead of `grpc-eio`

`grpc-eio` is the obvious dependency, but it is unusable on this switch:
- it pins `h2 < 0.13`, and `h2 0.12` requires `ocaml < 5.3` (via `hpack 0.12`),
  while the project runs ocaml 5.4 + `eio 1.x`;
- the `h2 0.13` that *does* support ocaml 5.4 + `eio 1.x` is excluded by that
  pin, and `grpc-eio 0.2.0` does not compile against `h2 0.13`'s client API.

The `grpc` **core** library (message framing + status), however, does build
against `h2 0.13`. And the only thing `grpc-eio` adds on top is a ~100-line
client glue over `h2-eio`. So we depend on `grpc` core and write that glue
ourselves in `channel`.

One further obstacle: `h2-eio`/`gluten-eio`'s client entry points constrain
their socket to `_ Eio.Net.stream_socket`, but the TLS flow we must use
(`Tls_eio.client_of_flow`, required for :443) is an `Eio.Flow.two_way`, **not**
a `stream_socket` (it has no `Socket` capability) — even though gluten's IO
loop only ever performs plain `Eio.Flow` reads/writes/shutdown on it. `eio_gluten`
re-expresses gluten-eio's client IO loop with the socket typed (by inference)
as `_ Eio.Flow.two_way`, the looser type the loop has always needed, so HTTP/2
runs directly over the TLS flow with no coercion. (Adapted from gluten-eio,
BSD-3-Clause.)

### 4. Auth is the same two-step flow, expressed over gRPC

`AuthService.Auth(secret)` returns a short-lived JWT (this is the only
unauthenticated call); the JWT then rides in the `authorization` metadata of
every other call — the raw token, **no `Bearer` prefix** (matching the
official Finam clients). The JWT `exp` claim drives refresh-before-expiry, the
same cache discipline as the REST `Finam.Auth`.

### 5. Live feed is native gRPC streaming, no poller

The REST adapter runs a WS-primary + REST-poll-fallback `Transport_supervisor`,
and polls REST for the spot tape because Finam's WS only stubs spot. gRPC has
no such gap: `MarketDataService.SubscribeBars`, `SubscribeLatestTrades`, and
`OrdersService.SubscribeTrades` are real server-streams over the one multiplexed
HTTP/2 connection. Each subscription is a `Stream_runner` — a fiber that
re-issues the streaming call on drop. Replayed prefixes on re-subscribe are
suppressed by the shared `Acl_common.Stream_dedup` (bars keyed by
`(instrument, timeframe)`, fills by `placement_id`) and, for the public tape, a
`trade_id` high-water that persists across re-subscribes. The
`Transport_supervisor` is intentionally **not** reused: its poll-fallback
machinery is dead weight for a pure-streaming transport.

## Consequences

- A `protoc` toolchain is now a build prerequisite for the broker BC (documented
  in the howto). The opam package metadata does not list the gRPC stack, because
  `grpc 0.2.0`'s stale `h2 < 0.13` bound cannot be expressed as a satisfiable
  constraint alongside `eio 1.x` on ocaml 5.4; the howto pins the working set
  explicitly (`opam install grpc-eio eio.1.3 h2.0.13.0 h2-eio.0.13.0
  --ignore-constraints-on h2,h2-eio`, then `ocaml-protoc-plugin`).
- The adapter reaches `Broker.S` parity with the REST `finam` adapter (bars,
  venues, place/cancel/get order, per-order trades, live bars/tape/fills) over a
  single transport, validated end-to-end against the live endpoint by
  `broker/test/grpc_smoke/finam_grpc_auth_probe.ml`.
- gRPC's spot tape (`SubscribeLatestTrades`) is a genuine improvement over the
  REST adapter's poller; if it proves reliable for spot equities it is the
  preferred footprint source.
