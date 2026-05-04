open Core

type t = {
  instrument : Broker_queries.Instrument_view_model.t;
  timeframe : string;
  bar : Broker_queries.Candle_view_model.t;
}
[@@deriving yojson]

let of_domain ~instrument ~timeframe ~bar =
  {
    instrument = Broker_queries.Instrument_view_model.of_domain instrument;
    timeframe = Timeframe.to_string timeframe;
    bar = Broker_queries.Candle_view_model.of_domain bar;
  }
