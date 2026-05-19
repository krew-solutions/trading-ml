(** A book's subscription to an alpha source on a specific
    instrument: the triplet [(alpha_source_id, instrument,
    book_id)] meaning {b "when this alpha source emits a
    direction flip on this instrument, route the resulting
    construction intent to this book"}.

    Pure VO: no state machine, no events. The subscription
    {b is} the data, and the registry that owns the collection
    of subscriptions lives at the application layer.

    Two subscriptions are equal when all three fields match;
    operationally this means a duplicate
    [Subscribe_book_to_alpha_command] is idempotent — the same
    triplet does not create a second entry. *)

type t = {
  alpha_source_id : Alpha_source_id.t;
  instrument : Core.Instrument.t;
  book_id : Book_id.t;
}

val make :
  alpha_source_id:Alpha_source_id.t ->
  instrument:Core.Instrument.t ->
  book_id:Book_id.t ->
  t

val equal : t -> t -> bool
