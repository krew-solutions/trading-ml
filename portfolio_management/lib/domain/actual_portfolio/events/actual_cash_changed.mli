(** Domain Event: PM's actual_portfolio model recorded a cash change
    for [book_id]. Emitted by {!Actual_portfolio.apply_cash_change}.

    Past-tense name; pure data carrier. *)

type t = {
  book_id : Common.Book_id.t;
  delta : Decimal.t;  (** signed *)
  new_balance : Decimal.t;  (** signed; can be negative under margin *)
  occurred_at : int64;  (** epoch seconds *)
}
