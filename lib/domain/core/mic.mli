(** Market Identifier Code (ISO 10383). Identifies a trading venue
    or market segment globally — e.g. [MISX] (MOEX equity section),
    [RTSX] (MOEX FORTS), [IEXG] (SPB Exchange), [XNYS] (NYSE).

    Opaque to enforce the format (4 alphanumeric uppercase characters)
    at construction time. *)

type t = private string

val of_string : string -> t
(** Trims, upper-cases, and validates against ISO 10383 surface
    syntax (exactly 4 ASCII letters or digits). Raises
    [Invalid_argument] otherwise. *)

val to_string : t -> string

val equal : t -> t -> bool
val compare : t -> t -> int
val hash : t -> int
val pp : Format.formatter -> t -> unit
