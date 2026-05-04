type t = {
  book_id : Common.Book_id.t;
  trades : Common.Trade_intent.t list;
  computed_at : int64;
}
