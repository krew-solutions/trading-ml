(** Bollinger Bands: middle = SMA(n), upper/lower = middle +/- k * sigma. *)

val make : ?period:int -> ?k:float -> unit -> Indicator.t
