(** Logical partition key for an independently-gated portfolio. One
    [Risk_view.t] aggregate exists per [Book_id.t]; assessment is
    strictly per-book.

    Mirrors the same concept that lives in
    {!Portfolio_management.Common.Book_id} but is owned by this BC —
    cross-BC integration carries [book_id : string] on the wire and the
    smart constructor lifts it into the VO at the BC boundary. *)

type t = private string

val of_string : string -> t
(** Trims; rejects empty / whitespace-only. Raises [Invalid_argument]
    otherwise. *)

val to_string : t -> string

val equal : t -> t -> bool
val compare : t -> t -> int
val hash : t -> int
val pp : Format.formatter -> t -> unit
