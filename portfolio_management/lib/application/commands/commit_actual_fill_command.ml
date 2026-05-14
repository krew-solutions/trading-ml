type t = {
  book_id : string;
  instrument : string;
  new_position_quantity : string;
  new_avg_price : string;
  new_cash : string;
  occurred_at : string;
}
[@@deriving yojson]
