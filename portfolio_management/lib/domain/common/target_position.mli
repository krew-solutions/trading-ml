(** Desired position in one instrument, signed: positive = long,
    negative = short, zero = flat. Identified inside its book by the
    [instrument] key — at most one [Target_position.t] per
    [(book_id, instrument)] in any well-formed Target_portfolio. *)

type t = {
  book_id : Book_id.t;
  instrument : Core.Instrument.t;
  target_qty : Decimal.t;  (** signed *)
}

val equal : t -> t -> bool
(** Equality across all three fields. *)
