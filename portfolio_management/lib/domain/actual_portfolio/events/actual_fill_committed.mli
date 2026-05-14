(** Domain Event: PM's actual_portfolio model recorded a fill — both
    the new cash balance and the new per-instrument position state —
    atomically, from a single upstream
    [Reservation_filled_integration_event] published by Account.

    Past-tense name; pure data carrier. The atomic shape (single
    event for both fields) preserves the [equity = cash +
    Σ qty × mark] invariant across consumer observation: a downstream
    reader can never see the cash side advance without the matching
    position side, or vice versa.

    Emitted by {!Actual_portfolio.commit_fill}. *)

type t = {
  book_id : Common.Book_id.t;
  instrument : Core.Instrument.t;
  new_position_quantity : Decimal.t;
      (** Signed post-fill quantity; [Decimal.zero] denotes a closed
          position. *)
  new_avg_price : Decimal.t;
      (** Post-fill VWAP of the surviving position;
          [Decimal.zero] when [new_position_quantity] is zero. *)
  new_cash : Decimal.t;  (** Post-fill cash balance; can be negative under margin. *)
  occurred_at : int64;
}
