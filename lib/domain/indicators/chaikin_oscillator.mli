(** Chaikin Oscillator = EMA(A/D, fast) - EMA(A/D, slow). *)

val make : ?fast:int -> ?slow:int -> unit -> Indicator.t
