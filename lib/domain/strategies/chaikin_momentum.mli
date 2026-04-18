(** Chaikin Oscillator zero-cross momentum — the volume-side
    counterpart of {!Macd_momentum}. Chaikin oscillator is
    [EMA(A/D, fast) - EMA(A/D, slow)], structurally identical to
    MACD but fed by the Accumulation/Distribution line instead
    of price.

    Enter long on zero-line cross from ≤0 to >0 (accumulation
    regime starts), exit / reverse on the opposite cross. *)

open Core

type params = { fast : int; slow : int; allow_short : bool }

type state

val name : string
val default_params : params
val init : params -> state
val on_candle : state -> Instrument.t -> Candle.t -> state * Signal.t
