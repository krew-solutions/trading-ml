open Core

type t = {
  instrument : Queries.Instrument_view_model.t;
  timeframe : string;
  bar : Queries.Candle_view_model.t;
}
[@@deriving yojson]

let of_domain ~instrument ~timeframe ~bar =
  {
    instrument = Queries.Instrument_view_model.of_domain instrument;
    timeframe = Timeframe.to_string timeframe;
    bar = Queries.Candle_view_model.of_domain bar;
  }
