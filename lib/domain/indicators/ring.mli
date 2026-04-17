(** Tiny fixed-capacity ring buffer for O(1) windowed aggregates. *)

type 'a t

val create : capacity:int -> 'a -> 'a t
val push : 'a t -> 'a -> unit
val is_full : 'a t -> bool
val size : 'a t -> int
val capacity : 'a t -> int
val get : 'a t -> int -> 'a
val oldest : 'a t -> 'a
val newest : 'a t -> 'a
val fold : 'a t -> 'b -> ('b -> 'a -> 'b) -> 'b
val iter : 'a t -> ('a -> unit) -> unit
val copy : 'a t -> 'a t
