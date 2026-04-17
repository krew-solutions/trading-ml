(** Simple Moving Average. *)

type config = { period : int }

val make : period:int -> Indicator.t
