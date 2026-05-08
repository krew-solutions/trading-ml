type t = {
  book_id : string;
  symbol : string;
  delta_qty : string;
  new_qty : string;
  avg_price : string;
  occurred_at : string;
}
[@@deriving yojson]
