type t = {
  instrument : Paper_broker_inbound_queries.Instrument_view_model.t;
  timeframe : string;
  candle : Paper_broker_inbound_queries.Candle_view_model.t;
}
[@@deriving yojson]
