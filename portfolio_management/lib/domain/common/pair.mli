(** Ordered pair of distinct instruments, the unit of measurement for a
    pair-trading policy. The spread is defined as the [a]-leg minus
    [β · b]-leg (both legs in log-prices for the cointegrated mean-
    reversion policy), so [a] and [b] are NOT interchangeable: swapping
    them inverts the spread sign and the economic interpretation of every
    threshold downstream.

    Invariant: [a ≠ b] under {!Core.Instrument.equal}. Enforced at
    construction. *)

type t = private { a : Core.Instrument.t; b : Core.Instrument.t }

val make : a:Core.Instrument.t -> b:Core.Instrument.t -> t
(** Raises [Invalid_argument] when [Core.Instrument.equal a b]. *)

val a : t -> Core.Instrument.t
val b : t -> Core.Instrument.t

val equal : t -> t -> bool
(** Equality is order-sensitive: [(SBER, LKOH)] and [(LKOH, SBER)] are
    distinct pairs, by the spread-sign rationale above. *)

val contains : t -> Core.Instrument.t -> bool
(** [true] when the instrument matches either leg. *)
