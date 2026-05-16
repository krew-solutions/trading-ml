type t = {
  instrument : Portfolio_management_external_view_models.Instrument_view_model.t;
  timeframe : string;
  candle : Portfolio_management_external_view_models.Candle_view_model.t;
}
[@@deriving yojson]
