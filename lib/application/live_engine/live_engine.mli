(** Live strategy engine. Bridges a {!Strategies.Strategy.t} to a
    live {!Broker.client}: receives bars via {!on_bar}, feeds the
    strategy, translates {!Core.Signal.t} decisions into orders, and
    routes them through [Broker.place_order].

    Single-instrument, single-strategy MVP — one engine instance
    trades one [(instrument, strategy)] pair. Compose several to
    trade multiple instruments or run parallel strategies.

    Semantics match {!Engine.Backtest} bar-for-bar:

    - A signal emitted on bar T is queued; the order fires on bar
      T+1 and sizes from equity marked at [open T+1] ("next-bar
      execution" — no same-bar lookahead).
    - {!Engine.Risk.check} runs before every order; a rejection
      (max_leverage, max_gross_exposure, min_cash_buffer) drops the
      signal, matching the backtester's behaviour on the same limits.
    - The engine keeps its own {!Engine.Portfolio.t} and updates it
      synthetically on the expected fill price, which makes paper
      P&L converge with a backtest over the same candle stream.

    Real broker fills will drift from this expected ledger due to
    slippage / partial fills / rejections; reconciliation against
    [Broker.get_orders] is a separate concern not handled here. *)

open Core

type config = {
  broker : Broker.client;
  strategy : Strategies.Strategy.t;
  instrument : Instrument.t;
  initial_cash : Decimal.t;
  limits : Engine.Risk.limits;
  tif : Order.time_in_force;
  fee_rate : float;
  (** Commission multiplier on fill notional — mirrors
      {!Engine.Backtest.config.fee_rate} so a live-engine run with
      the same value produces the same Portfolio P&L as a backtest
      over identical candles. *)
}

type t

val make : config -> t

val on_bar : t -> Candle.t -> unit
(** Feed one bar into the engine. Executes any signal queued on the
    previous bar at [c.open_], then advances the strategy and queues
    any new non-Hold signal for the next bar. Re-entrant-safe via an
    internal mutex; idempotent on older-or-equal timestamps.

    Intended for single-threaded test driving. Live deployments use
    {!run} which drains an Eio stream in its own fiber. *)

val run : t -> source:Candle.t Eio.Stream.t -> unit
(** Stream-driver variant: pulls bars from [source] and feeds them
    into {!on_bar} one by one. Blocks (never returns on an
    unbounded source) — intended to be invoked inside
    [Eio.Fiber.fork_daemon], with WS bridges pushing upstream
    candles into [source] from their own fibers.

    Semantically equivalent to
    [Stream.iter (on_bar t) (Eio_stream.of_eio_stream source)] —
    this is the boundary at which the pull-driven pure pipeline
    meets Eio's push-driven concurrency. *)

val position : t -> Decimal.t
(** Running net position for [config.instrument] (positive = long,
    negative = short). Reads from the engine's internal portfolio;
    reflects what the engine *expected* to happen, not reconciled
    broker reality. *)

val portfolio : t -> Engine.Portfolio.t
(** Full portfolio snapshot: cash, positions, realized PnL.
    Updated synthetically at each simulated fill using the same
    {!Engine.Portfolio.fill} transitions as the backtester. *)

val placed : t -> Order.t list
(** Chronological list of orders the engine has submitted via
    [Broker.place_order]. Exposed for tests and diagnostics. *)

type fill_event = {
  client_order_id : string;
  actual_quantity : Decimal.t;
  actual_price : Decimal.t;
  actual_fee : Decimal.t;
}

val on_fill_event : t -> fill_event -> unit
(** Process a fill reported by the broker. Looks up the reservation
    by [client_order_id], commits it against the engine's portfolio
    via {!Engine.Step.commit_fill}, and evicts the mapping. Idempotent
    on unknown cids (warns and returns) — a fill event for an order
    the engine didn't place (e.g. from manual intervention on the
    broker) isn't a crash.

    Paper mode wires this to {!Paper.Paper_broker.on_fill} at
    construction; real brokers wire it from their WS bridges after
    parsing [order_update] frames. *)
