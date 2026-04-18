(** MFI (Money Flow Index) mean reversion — a volume-weighted twin
    of {!Rsi_mean_reversion}. Enters long when MFI falls below
    [lower] (volume-confirmed oversold), exits when it crosses back
    above [exit_long]. Short side mirrors when [allow_short].

    Rationale: RSI reads price-only momentum, MFI weights each
    bar's typical-price move by its volume, so oversold readings
    back-pressured by real institutional selling rank stronger
    than readings driven by thin trades. *)

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
