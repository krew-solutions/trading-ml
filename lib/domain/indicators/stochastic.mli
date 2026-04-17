(** Stochastic Oscillator (%K, %D). *)

val make : ?k_period:int -> ?d_period:int -> unit -> Indicator.t
