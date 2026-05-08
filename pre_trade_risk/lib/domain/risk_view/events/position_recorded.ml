type t = {
  book_id : Common.Book_id.t;
  instrument : Core.Instrument.t;
  delta_qty : Decimal.t;
  new_qty : Decimal.t;
  occurred_at : int64;
}

let make ~book_id ~instrument ~delta_qty ~new_qty ~occurred_at =
  { book_id; instrument; delta_qty; new_qty; occurred_at }
