type t = {
  book_id : string;
  instrument : Instrument_view_model.t;
  side : string;
  quantity : string;
}
[@@deriving yojson]
