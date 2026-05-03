(** Domain Event: PM's actual_portfolio model recorded a per-instrument
    position change for [book_id]. Emitted by
    {!Actual_portfolio.apply_position_change} on every applied delta
    (including the initial transition from absent to present and the
    closing transition to zero quantity).

    Past-tense name; pure data carrier. *)

type t = {
  book_id : Shared.Book_id.t;
  instrument : Core.Instrument.t;
  delta_qty : Decimal.t;  (** signed *)
  new_qty : Decimal.t;  (** signed *)
  avg_price : Decimal.t;  (** weighted-average after the change *)
  occurred_at : int64;  (** epoch seconds; provided by the upstream event *)
}
