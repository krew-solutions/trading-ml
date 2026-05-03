(** Output of [Reconciliation.diff]: a single per-instrument trade that,
    when executed, brings the actual portfolio one step closer to the
    target. Side and quantity are unsigned — direction is encoded in
    [side] (mirrors the wire shape used by Broker / Account command
    DTOs upstream and downstream of this BC).

    Always [quantity > 0]: a zero-delta target/actual pair produces no
    intent at all rather than an intent with [quantity = 0]. *)

type t = {
  book_id : Book_id.t;
  instrument : Core.Instrument.t;
  side : Core.Side.t;
  quantity : Decimal.t;  (** strictly positive *)
}

val equal : t -> t -> bool
