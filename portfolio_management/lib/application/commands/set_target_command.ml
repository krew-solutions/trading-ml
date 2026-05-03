type position = { instrument : string; target_qty : string } [@@deriving yojson]

type t = {
  book_id : string;
  source : string;
  proposed_at : string;
  positions : position list;
}
[@@deriving yojson]
