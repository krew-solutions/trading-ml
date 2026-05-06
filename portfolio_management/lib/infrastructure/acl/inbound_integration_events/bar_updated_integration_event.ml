type t = {
  instrument : Portfolio_management_inbound_queries.Instrument_view_model.t;
  timeframe : string;
  bar : Portfolio_management_inbound_queries.Candle_view_model.t;
}
[@@deriving yojson]
