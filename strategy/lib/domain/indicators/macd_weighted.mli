(** MACD-Weighted: same three-stage structure as MACD but with WMA smoothing
    instead of EMA. *)

val make : ?fast:int -> ?slow:int -> ?signal:int -> unit -> Indicator.t
