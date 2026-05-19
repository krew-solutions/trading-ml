(** Annualised fractional volatility of an instrument's price
    series, expressed as a non-negative {!Decimal.t}: [0.20]
    means "20% standard deviation per year".

    Volatility-aware sizing policies (target-vol overlay, Kelly
    with payoff variance, inverse-vol weighting) consume a value
    of this type and scale per-leg quantity accordingly. *)

type t

val zero : t

val of_decimal : Decimal.t -> t
(** Raises [Invalid_argument] when the input is strictly
    negative. Zero is admissible (degenerate but valid). *)

val to_decimal : t -> Decimal.t

val equal : t -> t -> bool

val compare : t -> t -> int
