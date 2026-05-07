open Core

type t = {
  instrument : Broker_queries.Instrument_view_model.t;
  timeframe : string;
  candle : Broker_queries.Candle_view_model.t;
}
[@@deriving yojson]

let of_domain ~instrument ~timeframe ~candle =
  {
    instrument = Broker_queries.Instrument_view_model.of_domain instrument;
    timeframe = Timeframe.to_string timeframe;
    candle = Broker_queries.Candle_view_model.of_domain candle;
  }
