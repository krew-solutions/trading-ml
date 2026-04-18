(** OBV / SMA(OBV) crossover: go long when On-Balance Volume
    crosses above its moving average (net accumulation turning
    positive), exit / reverse on the opposite cross.

    Rationale: OBV is a running sum of signed volume — rising OBV
    means volume is piling up on up-days. A cross over its own MA
    is the same regime-change signal as SMA-crossover on price,
    but sourced from volume flow rather than price. Often leads
    price by a few bars in institutional regimes. *)

open Core

type params = { period : int; allow_short : bool }

type state

val name : string
val default_params : params
val init : params -> state
val on_candle : state -> Instrument.t -> Candle.t -> state * Signal.t
