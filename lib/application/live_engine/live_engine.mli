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
    internal mutex; idempotent on older-or-equal timestamps. *)

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
