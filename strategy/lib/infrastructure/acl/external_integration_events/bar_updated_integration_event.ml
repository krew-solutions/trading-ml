type t = {
  instrument : Strategy_external_view_models.Instrument_view_model.t;
  timeframe : string;
  candle : Strategy_external_view_models.Candle_view_model.t;
}
[@@deriving yojson]
