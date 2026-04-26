(** Paper-trading decorator around any {!Broker.client}.

    Market data ([bars], [venues]) delegates to the wrapped source —
    live Finam, BCS or Synthetic — so charts and strategies see the
    same prices they would see in production. Order operations
    ([place_order], [get_orders], [get_order], [cancel_order]) are
    intercepted and simulated against an in-memory book; nothing
    reaches the upstream broker.

    Fill model: orders fill on the bar strictly following the one that
    was the "tail" when they were placed ("next-bar execution"), matching
    the backtester's assumption and avoiding same-bar lookahead. Market
    orders fill at the next bar's open; limits and stops fill when the
    next bar's range crosses the threshold. Stop-limit is not yet
    simulated — placed but never transitions past [New].

    Passive by design: pending orders do not auto-fill. Callers feed
    bars via {!on_bar} whenever a new candle is observed (typically
    wired to the same hook that pushes bars into the SSE stream). This
    keeps the decorator composable and unit-testable without a
    background fiber. *)

open Core

type t

val make :
  ?initial_cash:Decimal.t ->
  ?fee_rate:float ->
  ?slippage_bps:float ->
  ?participation_rate:float ->
  source:Broker.client ->
  unit ->
  t
(** [initial_cash] defaults to 1_000_000 — the same scale as
    {!Engine.Backtest.default_config}, so paper and backtest P&L are
    comparable out of the box.

    [fee_rate] (default [0.0]) is a multiplier on fill notional
    ([qty * price]) — set to [0.0005] to match the backtester's
    5-bps commission model.

    [slippage_bps] (default [0.0]) shifts the fill price against the
    trader on {!Market} and {!Stop} orders: buys pay [(1 + bps/1e4) *
    price], sells receive [(1 - bps/1e4) * price]. {!Limit} and
    {!Stop_limit} orders fill at their stated price and are not
    slipped — a limit order that triggers has already locked in its
    worst acceptable price.

    [participation_rate] (default [None] = unconstrained) caps how
    much of a bar's volume the engine is willing to consume, forcing
    partial fills for orders larger than [rate * bar.volume]. Leave
    it unset when bar volume is synthetic; set to e.g. [0.1] in live
    scenarios so a large order realistically splits across several
    bars. An order partially filled through this path transitions
    [New → Partially_filled] and only reaches [Filled] once its
    [remaining] reaches zero. *)

val as_broker : t -> Broker.client
(** Re-wrap [t] as a {!Broker.client} implementing the extended
    {!Broker.S} interface, with orders intercepted. *)

val on_bar : t -> instrument:Instrument.t -> Candle.t -> unit
(** Notify the decorator that a new bar has closed for [instrument].
    Triggers fill evaluation for all pending orders on that instrument.
    Idempotent when called with the same or older [ts]. *)

val place_order :
  t ->
  instrument:Instrument.t ->
  side:Side.t ->
  quantity:Decimal.t ->
  kind:Order.kind ->
  tif:Order.time_in_force ->
  client_order_id:string ->
  Order.t

val get_orders : t -> Order.t list
val get_order : t -> client_order_id:string -> Order.t
val cancel_order : t -> client_order_id:string -> Order.t

val get_executions : t -> client_order_id:string -> Order.execution list
(** Chronological list of executions (simulated fills) that match
    [client_order_id]. Empty for unknown cids. *)

type fill = {
  client_order_id : string;
  ts : int64;
  instrument : Instrument.t;
  side : Side.t;
  quantity : Decimal.t;
  price : Decimal.t;
  fee : Decimal.t;
}

val fills : t -> fill list
(** Chronological list of simulated fills. Exposed for diagnostics and
    tests; not part of the {!Broker.S} port. *)

val on_fill : t -> (fill -> unit) -> unit
(** Subscribe to fill events. Every subsequent fill (full or
    partial) invokes the callback synchronously, in-process, before
    {!on_bar} returns. Multiple subscriptions compose: all callbacks
    fire in registration order.

    Used by {!Live_engine} to commit its reservations against
    actual broker numbers — Paper is the stand-in for a real WS
    fill stream, with identical semantics on the consumer side. *)

val portfolio : t -> Engine.Portfolio.t
(** Current paper portfolio (cash + positions + realized PnL).
    Updated on every fill using {!Engine.Portfolio.fill}. Exposed for
    diagnostics, CLI order summaries and UI — not part of the port. *)
