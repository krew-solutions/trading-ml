open Core

let handle
    ~(push : instrument:Instrument.t -> timeframe:Timeframe.t -> Candle.t -> unit)
    (ie : Bar_updated_integration_event.t) : unit =
  let parsed =
    try
      Some
        ( Instrument_view_model.to_domain ie.instrument,
          Timeframe.of_string ie.timeframe,
          Candle_view_model.to_domain ie.candle )
    with _ -> None
  in
  match parsed with
  | Some (instrument, timeframe, candle) -> push ~instrument ~timeframe candle
  | None ->
      Log.warn
        "bar_updated_integration_event: malformed payload (sym=%s tf=%s) — dropping"
        ie.instrument.ticker ie.timeframe
