(** Bare instrument symbol — the issuer-side code: [SBER], [GAZP],
    [AAPL]. Carries no venue or trading-mode information; combine with
    {!Mic} (and optionally {!Board}) to form an {!Instrument}.

    Opaque to enforce the format (non-empty, no whitespace,
    upper-cased) at construction time. *)

type t = private string

val of_string : string -> t
(** Trims, upper-cases, and rejects empty / whitespace-containing
    inputs. Raises [Invalid_argument] otherwise. *)

val to_string : t -> string

val equal : t -> t -> bool
val compare : t -> t -> int
val hash : t -> int
val pp : Format.formatter -> t -> unit
