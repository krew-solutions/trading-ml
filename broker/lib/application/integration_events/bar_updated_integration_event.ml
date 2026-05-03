type t = {
  instrument : Queries.Instrument_view_model.t;
  timeframe : string;
  bar : Queries.Candle_view_model.t;
  is_revision : bool;
}
[@@deriving yojson]
