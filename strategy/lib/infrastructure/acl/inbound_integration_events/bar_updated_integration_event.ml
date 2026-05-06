type t = {
  instrument : Strategy_inbound_queries.Instrument_view_model.t;
  timeframe : string;
  bar : Strategy_inbound_queries.Candle_view_model.t;
}
[@@deriving yojson]
