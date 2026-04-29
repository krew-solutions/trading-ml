(** Alternative ring buffer — fully immutable, backed by [list].
    No [mutable] fields, no arrays. Same interface as {!Ring};
    drop-in replacement where you want the compiler to prove
    zero mutation.

    Trade-off vs. {!Ring}: list-of-pointers memory layout is
    less cache-friendly than a contiguous array, and each push
    allocates cons cells. For indicator windows up to a few
    hundred elements the difference is negligible. *)

type 'a t

val create : capacity:int -> _ -> 'a t
(** [create ~capacity _] — empty ring of given capacity. Second
    argument kept for signature parity with {!Ring.create} and
    ignored (a list-backed ring needs no default filler). *)

val push : 'a t -> 'a -> 'a t
(** [push r x] — new ring with [x] appended; oldest evicted if
    [r] was full. [r] itself unchanged. *)

val is_full : 'a t -> bool
val size : 'a t -> int
val capacity : 'a t -> int

val get : 'a t -> int -> 'a
(** [get r i] — element at position [i] in chronological order;
    [i = 0] is the oldest. O(i). *)

val oldest : 'a t -> 'a
val newest : 'a t -> 'a

val fold : 'a t -> 'b -> ('b -> 'a -> 'b) -> 'b
(** Fold chronologically, oldest to newest. *)

val iter : 'a t -> ('a -> unit) -> unit
(** Iterate chronologically, oldest to newest. *)
