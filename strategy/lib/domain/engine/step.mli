(** One iteration of the trading state machine — a single bar of
    signal → order translation. Shared between {!Backtest.run}
    (historical replay) and {!Live_engine} (streaming callback).

    The {!state} threads the strategy instance, portfolio, any
    signal queued from the previous bar, and the last-seen
    timestamp. Transitions are pure: no IO, no ports, no clock.

    Two primitives rather than one combined [apply]:

    - {!execute_pending} fires any queued signal at [c.open_] and
      returns the new state plus (if a trade happened) the
      [(original signal, settled trade)] pair.
    - {!advance_strategy} feeds [c] to the strategy and queues the
      emitted non-Hold signal for the next bar.

    Splitting lets {!Backtest} mark-to-market at [c.close] on the
    intermediate state for its equity curve, and lets
    {!Live_engine} submit the broker order for [settled] before
    advancing strategy state. Both callers invoke them in sequence.

    The pre-trade risk gate that used to live inside {!execute_pending}
    moved to the {!Pre_trade_risk} bounded context (plan M1). The
    cross-BC veto is reintroduced at the saga boundary by
    {!Pre_trade_risk.Assessment.assess} once Strategy publishes
    {!Signal_detected_integration_event} in M5 — Step itself just
    sizes the quantity from {!Risk.size_from_strength} and reserves
    unconditionally. *)

open Core

type config = {
  max_position_notional : Decimal.t;
      (** Per-instrument notional cap fed into
        {!Risk.size_from_strength}. Replaces the previous
        [limits : Risk.limits] field — the rest of [Risk.limits]
        (cash buffer, gross exposure, leverage) is enforced
        out-of-process at the saga boundary by
        {!Pre_trade_risk.Assessment.assess}. *)
  instrument : Instrument.t;
  fee_rate : Decimal.t;
  margin_policy : Account.Portfolio.Margin_policy.t;
      (** Per-instrument margin terms used when reserving Sell-open
          (short) portions. The reference engine plugs in a constant
          policy via {!Account.Portfolio.Margin_policy.constant}. *)
  auto_commit : bool;
      (** When [true], {!execute_pending} applies the fill to the
      portfolio immediately after reserving (atomic reserve+commit
      in one step). Backtest uses this — it has no broker latency.

      When [false], {!execute_pending} only reserves; the
      reservation stays open and callers must invoke {!commit_fill}
      when the broker reports an actual fill. Live engine mode. *)
}

type settled = {
  side : Side.t;
  quantity : Decimal.t;
  price : Decimal.t;
  fee : Decimal.t;
  reservation_id : int;
}

type state = private {
  strat : Strategies.Strategy.t;
  portfolio : Account.Portfolio.t;
  pending_signal : Signal.t option;
  last_bar_ts : int64;
  reservation_seq : int;
}

val make_state : strategy:Strategies.Strategy.t -> cash:Decimal.t -> state

val execute_pending : config -> state -> Candle.t -> state * (Signal.t * settled) option
(** Fire any pending signal at [c.open_]. Sizes via
    {!Risk.size_from_strength} (entries) or existing position
    (exits), then reserves via {!Account.Portfolio.reserve}. The
    pre-trade gate that used to run here moved to the
    {!Pre_trade_risk} BC; reservations now succeed unconditionally
    inside the engine and the cross-BC veto runs out-of-process via
    integration events. Exits require a position of the matching
    direction — Exit_long on a flat or short book returns [None]
    rather than doubling down. *)

val advance_strategy : config -> state -> Candle.t -> state

val commit_fill :
  state ->
  reservation_id:int ->
  actual_quantity:Decimal.t ->
  actual_price:Decimal.t ->
  actual_fee:Decimal.t ->
  state

val commit_partial_fill :
  state ->
  reservation_id:int ->
  actual_quantity:Decimal.t ->
  actual_price:Decimal.t ->
  actual_fee:Decimal.t ->
  state

val release : state -> reservation_id:int -> state
