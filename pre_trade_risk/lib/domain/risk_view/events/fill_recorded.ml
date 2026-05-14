type t = {
  book_id : Common.Book_id.t;
  instrument : Core.Instrument.t;
  new_position_quantity : Decimal.t;
  new_avg_price : Decimal.t;
  new_cash : Decimal.t;
  occurred_at : int64;
}

let make ~book_id ~instrument ~new_position_quantity ~new_avg_price ~new_cash ~occurred_at
    =
  { book_id; instrument; new_position_quantity; new_avg_price; new_cash; occurred_at }
