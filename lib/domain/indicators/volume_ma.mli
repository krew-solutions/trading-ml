(** Volume Moving Average: SMA of bar volumes over the last [period] bars. *)

val make : period:int -> Indicator.t
