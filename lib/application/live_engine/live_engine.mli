(** Live strategy engine. Bridges a {!Strategies.Strategy.t} to a
    live {!Broker.client}: receives bars via {!on_bar}, feeds the
    strategy, translates {!Core.Signal.t} decisions into orders, and
    routes them through [Broker.place_order].

    Single-instrument, single-strategy MVP — one engine instance
    trades one [(instrument, strategy)] pair. Compose several to
    trade multiple instruments or run parallel strategies.

    The engine does not maintain its own portfolio: position state is
    whatever the broker reports. For paper-mode smoke-tests this means
    querying {!Broker.get_orders} against the Paper decorator; for
    live deployments it means the real broker's order book. This
    keeps the engine free of a parallel state machine that could drift
    out of sync with the broker.

    Exit signals follow a simple convention: {!Enter_long} /
    {!Enter_short} translate to sized market orders; {!Exit_long} /
    {!Exit_short} close whatever position the engine believes it
    holds (tracked locally as a running qty counter, since polling
    the broker on every bar would be wasteful and racy). Order sizing
    comes from {!Risk.size_from_strength}. *)

open Core

type config = {
  broker : Broker.client;
  strategy : Strategies.Strategy.t;
  instrument : Instrument.t;
  initial_cash : Decimal.t;
  limits : Engine.Risk.limits;
  tif : Order.time_in_force;
}

type t

val make : config -> t

val on_bar : t -> Candle.t -> unit
(** Feed one bar into the engine. Advances the strategy state; if a
    non-Hold signal results, sends a market order via the broker.
    Re-entrant-safe via an internal mutex. Idempotent on older-or-
    equal timestamps — duplicate feeds from overlapping WS/poll
    sources don't double-trade. *)

val position : t -> Decimal.t
(** Running net position the engine believes it holds (positive =
    long, negative = short). Updated on every place_order return,
    not on actual broker fill confirmation — so it's a ledger of
    intent, not reconciled truth. Callers that need reconciled state
    should consult [Broker.get_orders]. *)

val placed : t -> Order.t list
(** Chronological list of orders the engine has submitted via
    [Broker.place_order]. Exposed for tests and diagnostics. *)
