(** Fixed-point decimal for prices/quantities. Avoids float rounding in money math.
    Represented as integer value with implicit 8-decimal scale. *)

type t

val scale : int
(** Implicit scale: [10^scale] units per 1.0. *)

val zero : t
val one : t

val of_int : int -> t
val of_float : float -> t
(** Lossy; use only at system boundaries (UI, JSON ingest). *)

val to_float : t -> float
val to_string : t -> string
val of_string : string -> t
(** Accepts [-?\d+(\.\d+)?]; raises [Invalid_argument] otherwise. *)

val add : t -> t -> t
val sub : t -> t -> t
val mul : t -> t -> t
(** Result is rescaled back to [scale]. *)

val div : t -> t -> t
(** Raises [Division_by_zero] if [b] is [zero]. *)
(*@ r = div a b
    raises Division_by_zero -> true *)

val neg : t -> t
val abs : t -> t

val compare : t -> t -> int
val equal : t -> t -> bool
val min : t -> t -> t
val max : t -> t -> t

val is_positive : t -> bool
val is_negative : t -> bool
val is_zero : t -> bool

