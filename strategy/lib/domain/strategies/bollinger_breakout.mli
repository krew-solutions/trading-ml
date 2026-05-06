(** Bollinger breakout: go long on close > upper band, go short on
    close < lower band. Exit at middle band. *)

open Core

type params = { period : int; k : float; allow_short : bool }

type state

val name : string
val default_params : params
val init : params -> state
val on_candle : state -> Instrument.t -> Candle.t -> state * Signal.t
