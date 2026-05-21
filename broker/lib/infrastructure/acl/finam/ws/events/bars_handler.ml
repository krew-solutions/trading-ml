open Core

let handle
    ~(push_to_stream :
       instrument:Instrument.t -> timeframe:Timeframe.t -> Candle.t -> unit)
    ~(publish_bar_updated :
       instrument:Instrument.t -> timeframe:Timeframe.t -> candle:Candle.t -> unit)
    ~(timeframes_fallback : Instrument.t -> Timeframe.t list)
    (ev : Bars.t) : unit =
  let tfs : Timeframe.t list =
    match ev.timeframe with
    | Some tf -> [ tf ]
    | None -> timeframes_fallback ev.instrument
  in
  List.iter
    (fun (tf : Timeframe.t) ->
      List.iter
        (fun (candle : Candle.t) ->
          push_to_stream ~instrument:ev.instrument ~timeframe:tf candle;
          publish_bar_updated ~instrument:ev.instrument ~timeframe:tf ~candle)
        ev.bars)
    tfs
