type t = {
  correlation_id : string;
  book_id : string;
  symbol : string;
  side : string;
  quantity : string;
  price : string;
}
[@@deriving yojson]
