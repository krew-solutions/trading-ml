(** Placement identity — the saga key sent to broker when the
    OrderTicket submits a slice. One ticket fans out N placements
    (N = 1 for Immediate, > 1 for slicing strategies); each
    placement gets its own [Placement_id.t], unique within the
    ticket. *)

type t = private int

val of_int : int -> t
(** Raises [Invalid_argument] when [n ≤ 0]. *)
(*@ r = of_int n
    requires n > 0
    ensures (r : int) = n *)

val to_int : t -> int
(*@ n = to_int x
    ensures (x : int) = n
    ensures n > 0 *)

val equal : t -> t -> bool
val compare : t -> t -> int
