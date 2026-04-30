type t = {
  side : string;
  instrument : Queries.Instrument_view_model.t;
  quantity : string;
  reason : string;
}
[@@deriving yojson]
