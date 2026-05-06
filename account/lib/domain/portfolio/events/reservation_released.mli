(** Domain Event: an earmark was removed without maturing into a fill
    (e.g. broker rejected the order, operator cancelled before
    submission). Released cash/qty becomes available again. *)

type t = { reservation_id : int; side : Core.Side.t; instrument : Core.Instrument.t }
