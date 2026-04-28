(** Bracket decorator: wraps any {!Strategy.S} with a pure
    risk-management overlay.

    The inner strategy is the sole source of entry intent
    ([Enter_long] / [Enter_short]). Once the decorator is in a
    position, it takes over exit decisions entirely — only
    TP / SL / timeout can close a bracketed trade, and the inner
    strategy's signals (Exit_*, flips, Hold) are ignored until
    the position is closed. This is an explicit design choice:
    brackets exist to make risk deterministic, and letting the
    inner strategy override them defeats the purpose.

    Barrier levels are sized off ATR at entry — the same volatility
    estimate you'd use for triple-barrier labelling. Wrap an
    inner strategy whose model was trained with the
    [triple-barrier] label mode, and pass the same
    [tp_mult] / [sl_mult] / [max_hold_bars] used at labelling
    time; that keeps training-time accuracy and trade-time PnL
    aligned. Mismatched multipliers silently decouple the two.

    Tie-break on a single bar that crosses both barriers: SL
    wins. This matches {!Ml.Triple_barrier.label} and is the
    conservative stance when intra-bar path is unknown. *)

open Core

type params = {
  tp_mult : float;
      (** Take-profit distance as a multiple of ATR at entry.
      Sensible range [0.5, 3.0]. *)
  sl_mult : float;
      (** Stop-loss distance as a multiple of ATR at entry.
      Sensible range [0.5, 2.0]. *)
  max_hold_bars : int;
      (** Force-exit after this many bars in position, regardless of
      TP/SL. Matches the [timeout] barrier in triple-barrier
      labelling. *)
  atr_period : int;  (** Wilder ATR period for volatility sizing. Default 14. *)
  inner : Strategy.t;
      (** The wrapped entry-signal source. Any {!Strategy.S}
      instance — a leaf strategy, a composite, anything. *)
}

type state

val name : string
val default_params : params

val init : params -> state
(** Raises [Invalid_argument] on non-positive multipliers or
    [max_hold_bars], or on [atr_period <= 1]. *)

val on_candle : state -> Instrument.t -> Candle.t -> state * Signal.t
