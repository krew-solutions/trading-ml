(** OrderTicket identity. Derived from the upstream
    [reservation_id] (Account-minted; one reservation → one ticket).
    Typed wrapper around [int] to keep ticket-level identity
    distinct from placement-level identity ([Placement_id.t]) at
    every signature site. *)

type t = private int

val of_int : int -> t
(*@ r = of_int n
    requires n > 0
    ensures (r : int) = n *)

val to_int : t -> int
val equal : t -> t -> bool
val compare : t -> t -> int
