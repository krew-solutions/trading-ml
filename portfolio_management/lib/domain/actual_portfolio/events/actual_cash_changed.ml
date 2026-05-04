type t = {
  book_id : Common.Book_id.t;
  delta : Decimal.t;
  new_balance : Decimal.t;
  occurred_at : int64;
}
