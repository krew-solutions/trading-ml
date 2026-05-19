(** Inbound CQRS command to register a
    {!Portfolio_management.Common.Alpha_subscription.t} in the
    per-source registry. Each successful invocation adds (or
    leaves in place) a [(alpha_source_id, instrument, book_id)]
    triplet; downstream [Direction_changed] events fan out to
    every book whose subscription matches the event's
    [(alpha_source_id, instrument)] pair.

    Wire shape mirrors {!Subscribe_book_to_alpha_command_t.t};
    this module re-exports the ATD-generated type and its
    Yojson <-> string projections so callers do not need to
    know about the [_t]/[_j] split. *)

include module type of struct
  include Subscribe_book_to_alpha_command_t
  include Subscribe_book_to_alpha_command_j
end

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t
