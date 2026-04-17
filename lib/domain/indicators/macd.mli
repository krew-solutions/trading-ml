(** MACD: EMA(fast) - EMA(slow), signal = EMA of MACD, histogram = MACD - signal. *)

val make : ?fast:int -> ?slow:int -> ?signal:int -> unit -> Indicator.t
