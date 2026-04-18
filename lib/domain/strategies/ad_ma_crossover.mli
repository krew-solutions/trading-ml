(** A/D Line / SMA(A/D) crossover. Accumulation/Distribution
    weights each bar's volume by where the close fell within the
    bar's range — [(close - low) - (high - close)] / (high - low).
    Running sum of those values crossing above its own moving
    average signals a swing from net distribution to net
    accumulation.

    Structurally identical to {!Obv_ma_crossover}; the difference
    is only in how each bar's volume contribution is computed. *)

open Core

type params = { period : int; allow_short : bool }

type state

val name : string
val default_params : params
val init : params -> state
val on_candle : state -> Instrument.t -> Candle.t -> state * Signal.t
