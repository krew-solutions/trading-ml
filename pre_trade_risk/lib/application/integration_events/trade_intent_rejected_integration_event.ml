type t = {
  correlation_id : string;
  book_id : string;
  symbol : string;
  side : string;
  quantity : string;
  reason : string;
}
[@@deriving yojson]
