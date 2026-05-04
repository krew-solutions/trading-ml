(** Identifier of an alpha source: a system-of-origin for directional
    forecasts on instruments. Mirrors industry usage: «alpha» = source
    of edge / forecast / informational advantage; an alpha source can
    be a quant strategy, a research-pipeline output, an ML model
    inferring direction, an analyst override, etc. PM treats them all
    uniformly through this identifier — the actual provider is opaque
    to PM logic.

    Opaque to enforce format (non-empty, length-bounded, no
    surrounding whitespace) at construction time. Same shape as
    {!Book_id} for the same reasons. *)

type t = private string

val max_length : int

val of_string : string -> t
(** Trims surrounding whitespace, rejects an empty result and any
    input longer than [max_length] after trimming. Raises
    [Invalid_argument] on a violation. *)

val to_string : t -> string

val equal : t -> t -> bool
val compare : t -> t -> int
val hash : t -> int
val pp : Format.formatter -> t -> unit
