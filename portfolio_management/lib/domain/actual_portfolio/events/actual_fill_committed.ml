open Core

type t = {
  book_id : Common.Book_id.t;
  instrument : Instrument.t;
  new_position_quantity : Decimal.t;
  new_avg_price : Decimal.t;
  new_cash : Decimal.t;
  occurred_at : int64;
}
