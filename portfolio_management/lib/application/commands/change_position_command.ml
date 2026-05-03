type t = {
  book_id : string;
  instrument : string;
  delta_qty : string;
  new_qty : string;
  avg_price : string;
  occurred_at : string;
}
[@@deriving yojson]
