(** Trading mode / board within a venue — the QUIK-style [classCode]
    or its equivalent: [TQBR] (MOEX main equity session, T+1),
    [SMAL] (MOEX small lots), [SPBFUT] (MOEX FORTS futures),
    [TQOB] (MOEX gov bonds), [CETS] (MOEX FX), etc.

    A board defines the *mechanics* of trading (hours, settlement,
    lot size, tick, price collar) within a single {!Mic}. The same
    issuer-side {!Ticker} can trade in several boards at the same
    venue, each with its own order book.

    Opaque, but deliberately not constrained to a closed variant:
    exchanges add new boards independently and we don't want a
    rebuild every time. Validation is minimal (non-empty, no
    whitespace, upper-cased). *)

type t = private string

val of_string : string -> t

val to_string : t -> string

val equal : t -> t -> bool
val compare : t -> t -> int
val hash : t -> int
val pp : Format.formatter -> t -> unit
