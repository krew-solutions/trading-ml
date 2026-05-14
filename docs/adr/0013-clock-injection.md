# 0013. Time injection: Domain takes timestamps as arguments, Application reads from an injected Clock

- Status: accepted
- Date: 2026-05-14
- Deciders: @emacsway
- Supersedes: —
- Superseded by: —

## Context

The system needs to operate in two modes:

- **Live** — bars and fills stream in at wall-clock time; every
  reading of "what time is it now" should reflect the host clock.
- **Backtest** — a deterministic replay of historical (or
  synthetic) bars at arbitrary host-clock speed. Two runs over the
  same bar stream must produce byte-identical outbound events,
  snapshots, and audit logs.

Until now, places in the codebase that needed an ambient timestamp
called `Unix.gettimeofday ()` directly. This is harmless in live
mode and structurally wrong in backtest mode for three reasons:

1. **Non-determinism.** Two backtest runs over the same input
   stamp events with different times, so any snapshot test or
   diff-against-reference comparison becomes brittle.
2. **Audit-timeline divergence.** A backtest over 2023 data run
   in 2026 stamps every derived event with 2026, breaking
   correlation with the underlying bar timestamps.
3. **Mixed clocks.** Three independent ACL handlers (PM, PTR, EMS
   kill-switch) each call `Unix.gettimeofday` separately for the
   same upstream fact, so they record three different times for
   the one event.

The Domain Layer separately must not read ambient time. Domain
methods are pure functions of their inputs; an embedded
`gettimeofday` call would make them non-reproducible and would
defeat formal verification (Why3 proofs do not see a "current
time" oracle).

## Decision

Adopt a three-rule discipline for time:

### Rule 1 — Domain takes timestamps as explicit arguments

Domain methods that need a timestamp accept it as a named
parameter (`~occurred_at`, `~fill_ts`, etc.). They never read
ambient time. This is the existing convention for most of the
Domain Layer; the rule makes it explicit and project-wide.

This rule is enforced by `dune`: the Domain Layer's library does
not list `unix` in its `(libraries …)` clause, so a stray
`Unix.gettimeofday` would fail to link.

### Rule 2 — Application Layer obtains time from a `Clock`

The Application Layer is the boundary where ambient time enters
the system. It does so through a first-class
`Datetime.Clock.t` value — an opaque carrier of a "read current
time" thunk that returns `int64` epoch seconds.

To prevent the `Clock` abstraction from bleeding into every
workflow / handler, BC factories accept a closed-over
`~now : unit -> int64` argument rather than the `Clock.t`
itself. The composition root builds the `Clock.t`, derives the
closure via `Datetime.Clock.now`, and threads it through the
factory.

### Rule 3 — Composition root chooses the implementation

The composition root (`bin/main.ml`) instantiates exactly one
clock for the lifetime of the process:

- **Live mode** — `Datetime.Unix_clock.make ()`. Every read
  returns the host's current epoch-seconds via
  `Unix.gettimeofday`.
- **Backtest mode** — `Datetime.Virtual_clock.make ()`. The
  composition root subscribes the virtual clock to the bar
  stream (`broker.bar-updated`); every observed bar advances
  the clock to that bar's `candle.ts`. Reads before the first
  bar return `0L`.

In both cases, the resulting `Clock.t` is converted to a `now`
closure and passed to every BC factory that needs ambient time.

## Scope

This ADR governs **Application-Layer ambient time** — workflows,
ACL handlers, factory wiring. It explicitly does **not** govern:

- **Live-broker authentication** (JWT-expiry checks in
  `broker/lib/infrastructure/acl/{bcs,finam}/auth.ml`). JWTs are
  signed against wall-clock time by the issuer; the verifier
  must check against wall-clock too. Backtest never exercises
  the live-broker auth path.
- **HTTP request-latency measurement** (`lib/infrastructure/
  inbound/http/http.ml`). This is a real wall-clock duration by
  definition; a virtual clock would always show zero elapsed
  time.
- **Tests.** Tests run in real time and pass timestamps
  explicitly or use wall-clock at their convenience.
- **One-shot CLI batch tools** (`bin/train_logistic.ml`,
  `bin/export_training_data.ml`). These run outside the
  live/backtest composition; their `now_ts` is metadata, not
  semantics.

If a future Application-Layer caller has a genuine need for
wall-clock independent of the simulated timeline (e.g.,
deadline-driven retry inside a workflow), it takes an extra
`~wall_now : unit -> int64` injected from the composition root,
distinct from `~now`. We expect this to be rare.

## Bar-stream subscription details (backtest)

The composition root subscribes the virtual clock to
`in-memory://broker.bar-updated` with its own consumer group
(`clock-tick`), distinct from every BC's group. The handler
parses the bar's `candle.ts` and calls `Virtual_clock.set`.

**Ordering caveat.** The in-memory bus dispatches subscribers
within different groups independently. The virtual clock's tick
is therefore not strictly ordered before any BC handler's
processing of the same bar. In practice this is benign:

- The bar IE itself carries `candle.ts`; downstream events
  derived from the bar (paper-broker `Order_filled` →
  `Commit_fill_command` → `Reservation_filled`) propagate that
  same timestamp through their `~fill_ts` arguments without
  consulting ambient time.
- The places that actually call `now ()` — PM/PTR ACL stamping
  of the `Reservation_filled` commit, EMS kill-switch
  `occurred_at`, rate limiter window — sit *downstream* of bar
  processing. By the
  time they fire, the virtual clock has typically advanced to
  the bar's timestamp.

If a future scenario requires stricter ordering (e.g., a
synchronous "tick before publish" guarantee), the composition
root can advance the clock inline with `Bus.publish bar` instead
of subscribing — without touching any BC code.

## Consequences

**Easier**:

- Backtest is deterministic by construction. Two replays over the
  same bar stream produce identical timestamps in every derived
  event.
- Audit trails are coherent: every event stamped by the
  Application Layer in a backtest carries a time on the simulated
  bar timeline, not the host's 2026 wall clock.
- Domain Layer stays pure and Why3-friendly: timestamps are inputs,
  never side effects.
- Single point of substitution: switching live ↔ backtest at the
  composition root is a one-line change.

**Harder**:

- BC factories grow one more parameter (`~now`). The signature
  churn is a one-time cost; the closure pattern keeps the BC
  internals oblivious to whether time is real or virtual.
- The bar-tick subscription introduces an implicit dependency
  ordering between "advance clock" and "process derived events".
  Documented under the ordering caveat above; in the current
  call graph it is benign.

**To watch for**:

- A new Application-Layer caller might quietly reintroduce
  `Unix.gettimeofday` and the gap would not surface until backtest
  divergence is noticed. The `unix` library should not appear in
  any new factory / handler library's `(libraries …)`; CI can
  optionally grep for `gettimeofday` outside the documented scope
  set.
- `Virtual_clock.set` is not enforced monotonic. The bar-tick
  subscriber is expected to advance forward; a future caller that
  rewinds the clock would silently invalidate downstream
  consumers. Monotonicity can be added later if a real out-of-order
  source emerges.

## References

- ADR 0001 — Hexagonal Architecture (layering rule the Domain /
  Application boundary respects).
- ADR 0011 — Risk-evacuation and Place-Order saga (the EMS
  rate-limit / kill-switch were the first callers to invent a
  private `now` closure; this ADR formalises the pattern).
- Hexagonal Architecture, Alistair Cockburn — ports & adapters for
  ambient I/O; "system clock" is the canonical example of a port
  every layered architecture eventually re-discovers.
