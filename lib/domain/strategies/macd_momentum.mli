(** MACD momentum: enter long on histogram sign flip from -/0 to +,
    exit / reverse on the opposite flip. *)

open Core

type params = { fast : int; slow : int; signal : int; allow_short : bool }

type state

val name : string
val default_params : params
val init : params -> state
val on_candle : state -> Instrument.t -> Candle.t -> state * Signal.t
