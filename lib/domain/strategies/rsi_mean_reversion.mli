(** RSI mean reversion: enter long when RSI < lower threshold (oversold),
    exit when RSI > exit_long threshold. Short side mirrors. *)

open Core

type params = {
  period : int;
  lower : float;
  upper : float;
  exit_long : float;
  exit_short : float;
  allow_short : bool;
}

type state

val name : string
val default_params : params
val init : params -> state
val on_candle : state -> Instrument.t -> Candle.t -> state * Signal.t
