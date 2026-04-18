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
    advancing strategy state. Both callers invoke them in sequence. *)

open Core

type config = {
  limits : Risk.limits;
  instrument : Instrument.t;
  fee_rate : float;
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
  (** Handle into [state.portfolio.reservations] — consumers call
      {!Portfolio.commit_fill} or {!Portfolio.release} with this id
      when the broker reports the corresponding fill or rejection.
      In Backtest the commit is immediate (same tick); in live mode
      it awaits a broker event. *)
}

type state = private {
  strat : Strategies.Strategy.t;
  portfolio : Portfolio.t;
  pending_signal : Signal.t option;
  last_bar_ts : int64;
  reservation_seq : int;
  (** Monotonic counter; every {!execute_pending} that produces a
      settled trade consumes one slot for the new
      [reservation_id]. *)
}

val make_state :
  strategy:Strategies.Strategy.t -> cash:Decimal.t -> state

val execute_pending :
  config -> state -> Candle.t -> state * (Signal.t * settled) option
(** Fire any pending signal at [c.open_]. Sizes via
    {!Risk.size_from_strength} (entries) or existing position
    (exits), gates through {!Risk.check}, applies
    {!Portfolio.fill}. Returns the updated state (with pending
    cleared) and, if a trade happened, the signal that caused it
    plus the {!settled} trade details. Exits require a position of
    the matching direction — Exit_long on a flat or short book
    returns [None] rather than doubling down. *)

val advance_strategy : config -> state -> Candle.t -> state
(** Feed [c] to the strategy; any non-Hold signal becomes the new
    pending, to be executed on the next bar's open. Also advances
    [last_bar_ts]. *)

val commit_fill :
  state ->
  reservation_id:int ->
  actual_quantity:Core.Decimal.t ->
  actual_price:Core.Decimal.t ->
  actual_fee:Core.Decimal.t ->
  state
(** Settle a reservation with actual broker numbers. Used in Live
    mode when a broker fill event arrives — the engine looks up the
    reservation by [reservation_id] and applies
    {!Portfolio.commit_fill}. Raises [Not_found] when the id is
    unknown (already settled or never existed).

    Not called in Backtest: [auto_commit = true] handles it inside
    {!execute_pending}. *)

val release :
  state -> reservation_id:int -> state
(** Drop a reservation without a fill — used on broker reject /
    cancel. No-op when the id is unknown. *)
