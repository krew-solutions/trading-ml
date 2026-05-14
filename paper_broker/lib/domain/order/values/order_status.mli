(** Lifecycle status of a working order inside paper_broker.

    Terminal statuses ([Filled], [Cancelled], [Rejected], [Expired])
    cannot transition any further; only [New] and [Partially_filled]
    are still "working" and can receive fills. *)

type t = New | Partially_filled | Filled | Cancelled | Rejected | Expired

val is_terminal : t -> bool
(** True for [Filled], [Cancelled], [Rejected], [Expired]. *)

val to_string : t -> string
