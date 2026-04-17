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

val make : source:Broker.client -> unit -> t

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

type fill = {
  client_order_id : string;
  ts : int64;
  instrument : Instrument.t;
  side : Side.t;
  quantity : Decimal.t;
  price : Decimal.t;
}

val fills : t -> fill list
(** Chronological list of simulated fills. Exposed for diagnostics and
    tests; not part of the {!Broker.S} port. *)
