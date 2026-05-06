(** Fixed-point decimal for prices/quantities. Avoids float rounding in money math.
    Represented as integer value with implicit 8-decimal scale. *)

type t
(** Logical view: the underlying scaled integer. [add]/[sub] are
    linear over [raw]; [mul]/[div] rescale (specs omitted — Gospel's
    stdlib has no integer power). *)
(*@ model raw : integer *)

val scale : int
(** Implicit scale: [10^scale] units per 1.0. *)

val zero : t
(*@ r = zero
    ensures r.raw = 0 *)

val one : t

val of_int : int -> t

val of_float : float -> t
(** Lossy; use only at system boundaries (UI, JSON ingest). *)

val to_float : t -> float
val to_string : t -> string

val of_string : string -> t
(** Accepts [-?\d+(\.\d+)?]; raises [Invalid_argument] otherwise. *)

val add : t -> t -> t
(*@ r = add a b
    ensures r.raw = a.raw + b.raw *)

val sub : t -> t -> t
(*@ r = sub a b
    ensures r.raw = a.raw - b.raw *)

exception Decimal_overflow
(** Raised by {!mul} / {!div} when the mathematically-exact result
    does not fit in the int64 representation. Distinct from
    {!Division_by_zero}: it signals "this result is unrepresentable",
    not "this operation is undefined". The pre-Int128 implementation
    silently wrapped on overflow; raising here turns a corruption
    bug into a loud failure. *)

val mul : t -> t -> t
(** Result is rescaled back to [scale]. Raises {!Decimal_overflow}
    when [|a.raw * b.raw / unit_| > Int64.max_int]. The intermediate
    [a.raw * b.raw] is computed in 128-bit arithmetic, so no overflow
    short of the final narrow-back step is possible. *)

val div : t -> t -> t
(** Raises [Division_by_zero] if [b] is [zero]. Raises
    {!Decimal_overflow} when [|a.raw * unit_ / b.raw| > Int64.max_int].
    The intermediate [a.raw * unit_] is computed in 128-bit arithmetic. *)
(*@ r = div a b
    raises Division_by_zero -> b.raw = 0 *)

val neg : t -> t
(*@ r = neg a
    ensures r.raw = -a.raw *)

val abs : t -> t
(*@ r = abs a
    ensures r.raw = if a.raw < 0 then -a.raw else a.raw *)

val compare : t -> t -> int
(*@ r = compare a b
    ensures r < 0 <-> a.raw < b.raw
    ensures r = 0 <-> a.raw = b.raw
    ensures r > 0 <-> a.raw > b.raw *)

val equal : t -> t -> bool
(*@ r = equal a b
    ensures r <-> a.raw = b.raw *)

val min : t -> t -> t
(*@ r = min a b
    ensures r.raw = if a.raw <= b.raw then a.raw else b.raw *)

val max : t -> t -> t
(*@ r = max a b
    ensures r.raw = if a.raw >= b.raw then a.raw else b.raw *)

val is_positive : t -> bool
(*@ r = is_positive a
    ensures r <-> a.raw > 0 *)

val is_negative : t -> bool
(*@ r = is_negative a
    ensures r <-> a.raw < 0 *)

val is_zero : t -> bool
(*@ r = is_zero a
    ensures r <-> a.raw = 0 *)
