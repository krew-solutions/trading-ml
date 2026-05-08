type t = {
  book_id : Common.Book_id.t;
  delta : Decimal.t;
  new_balance : Decimal.t;
  occurred_at : int64;
}

let make ~book_id ~delta ~new_balance ~occurred_at =
  { book_id; delta; new_balance; occurred_at }
