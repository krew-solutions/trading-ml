type t = {
  instrument : Paper_broker_external_view_models.Instrument_view_model.t;
  timeframe : string;
  candle : Paper_broker_external_view_models.Candle_view_model.t;
}
[@@deriving yojson]
