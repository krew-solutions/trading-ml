(** Tiny fixed-capacity ring buffer for O(1) windowed aggregates.

    Persistent API: {!push} returns a new ring with the element
    appended; the input is unchanged. Callers never need an
    explicit copy — the old ring remains safe to reuse, and any
    attempt to "mutate" it is a type error because [push] takes
    and returns [t], not [unit].

    Internally the ring still owns a mutable {!Stdlib.array} for
    speed (contiguous memory, no cons-cell allocation per push),
    but the mutation is hidden from callers: each [push]
    allocates a fresh array and writes to it before returning,
    so observable state from the outside is purely value-based.

    For a variant that also removes the internal [array] mutation
    — pure [list] backing, zero [mutable] keywords anywhere — see
    {!Ring_im}. *)

type 'a t

val create : capacity:int -> 'a -> 'a t
(** [create ~capacity default] — empty ring sized to hold up to
    [capacity] elements. [default] fills unoccupied slots in the
    backing array; never observable by callers. *)

val push : 'a t -> 'a -> 'a t
(** [push r x] — returns a new ring with [x] appended. When [r]
    is already full, the oldest element is evicted in the new
    ring. [r] itself is unchanged. *)

val is_full : 'a t -> bool
val size : 'a t -> int
val capacity : 'a t -> int

val get : 'a t -> int -> 'a
(** [get r i] — element at position [i] in chronological order;
    [i = 0] is the oldest. *)

val oldest : 'a t -> 'a
val newest : 'a t -> 'a

val fold : 'a t -> 'b -> ('b -> 'a -> 'b) -> 'b
val iter : 'a t -> ('a -> unit) -> unit
