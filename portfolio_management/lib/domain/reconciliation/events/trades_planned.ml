type t = {
  book_id : Shared.Book_id.t;
  trades : Shared.Trade_intent.t list;
  computed_at : int64;
}
