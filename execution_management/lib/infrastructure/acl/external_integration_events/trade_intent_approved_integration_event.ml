type t = {
  correlation_id : string;
  book_id : string;
  symbol : string;
  side : string;
  quantity : string;
}
[@@deriving yojson]
