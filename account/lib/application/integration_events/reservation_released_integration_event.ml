type t = {
  reservation_id : int;
  side : string;
  instrument : Queries.Instrument_view_model.t;
}
[@@deriving yojson]
