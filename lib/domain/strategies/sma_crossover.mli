(** Classic dual-SMA crossover: go long when the fast SMA crosses above the
    slow SMA, exit long (and optionally go short) on the opposite cross.

    Position state is tracked internally so the strategy emits [Enter_long]
    only on the bar where the cross first occurs, not on every bar in the
    trend. *)

open Core

type params = { fast : int; slow : int; allow_short : bool }

type state

val name : string
val default_params : params
val init : params -> state
val on_candle : state -> Instrument.t -> Candle.t -> state * Signal.t
