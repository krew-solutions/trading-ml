(** Hedge ratio β in a pair-trading context. The spread of an ordered
    pair [(a, b)] is defined as [a-leg minus β · b-leg] (in log-prices
    when used by the cointegrated mean-reversion policy).

    Strictly positive by domain invariant: a non-positive β would either
    flip the spread sign (negative) or collapse the b-leg out of the
    hedge (zero), both of which break the pair-trading semantics
    pair_mean_reversion relies on. Enforced at construction. *)

type t = private Decimal.t

val of_decimal : Decimal.t -> t
(** Raises [Invalid_argument] when [d <= 0]. *)

val to_decimal : t -> Decimal.t

val equal : t -> t -> bool
val compare : t -> t -> int
