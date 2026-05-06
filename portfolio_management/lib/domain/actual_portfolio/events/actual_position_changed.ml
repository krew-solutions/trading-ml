open Core

type t = {
  book_id : Common.Book_id.t;
  instrument : Instrument.t;
  delta_qty : Decimal.t;
  new_qty : Decimal.t;
  avg_price : Decimal.t;
  occurred_at : int64;
}
