type t = {
  book_id : Book_id.t;
  positions : Target_position.t list;
  source : string;
  proposed_at : int64;
}
