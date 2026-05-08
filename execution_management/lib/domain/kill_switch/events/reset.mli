(** Domain event: an operator manually reset the kill switch and the
    peak-equity baseline; submissions are allowed to resume. *)

type t = { new_peak_equity : Decimal.t; occurred_at : int64 }

val make : new_peak_equity:Decimal.t -> occurred_at:int64 -> t
