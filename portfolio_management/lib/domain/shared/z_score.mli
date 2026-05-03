(** Standardised residual: [(x − μ) / σ]. Unbounded in theory but
    bounded by the data in practice. Wraps [float] to keep raw IEEE-754
    sentinels (NaN, ±∞) out of the comparison surface — the construction
    smart constructor rejects them, so any well-typed [t] is finite. *)

type t = private float

val of_float : float -> t
(** Raises [Invalid_argument] on NaN or ±∞. *)

val to_float : t -> float

val abs : t -> float
(** Absolute value, in the underlying [float] domain (always finite). *)

val equal : t -> t -> bool
val compare : t -> t -> int
