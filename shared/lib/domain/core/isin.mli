(** International Securities Identification Number (ISO 6166).
    12-character alphanumeric code with a Luhn-mod-10 checksum,
    e.g. [RU0009029540] (Sberbank common stock).

    Opaque to enforce both the surface format and the checksum at
    construction time, so an [Isin.t] in hand is guaranteed to be
    structurally valid. *)

type t = private string

val of_string : string -> t
(** Trims, upper-cases, validates length (12), character set
    ([A-Z0-9]) and Luhn-mod-10 checksum. Raises [Invalid_argument]
    on any failure. *)

val to_string : t -> string

val equal : t -> t -> bool
val compare : t -> t -> int
val hash : t -> int
val pp : Format.formatter -> t -> unit
