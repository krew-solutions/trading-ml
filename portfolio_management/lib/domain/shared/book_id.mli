(** Logical partition for a portfolio. One book per independently-managed
    portfolio (e.g. one per running strategy instance, or one per trading
    account in a future multi-account setup). Every Portfolio Management
    command, event and aggregate carries [Book_id.t] so that target and
    actual portfolios for unrelated books cannot accidentally cross-pollute.

    Opaque to enforce the format (non-empty, length-bounded, no surrounding
    whitespace) at construction time. The bound is conservative: 64 chars
    is enough for any reasonable strategy id and short enough to fit a
    log line; harder limits are easy to relax later, easy guarantees are
    not. *)

type t = private string

val max_length : int
(** Upper bound on raw string length, in bytes. *)

val of_string : string -> t
(** Trims surrounding whitespace, rejects an empty result and any input
    longer than [max_length] after trimming. Raises [Invalid_argument]
    on a violation. *)

val to_string : t -> string

val equal : t -> t -> bool
val compare : t -> t -> int
val hash : t -> int
val pp : Format.formatter -> t -> unit
