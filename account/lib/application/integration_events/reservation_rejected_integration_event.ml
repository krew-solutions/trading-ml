type t = {
  side : string;
  instrument : Queries.Instrument_view_model.t;
  quantity : float;
  reason : string;
}
[@@deriving yojson]
