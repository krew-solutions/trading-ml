open Core

let make ~bus : instrument:Instrument.t -> timeframe:Timeframe.t -> unit =
  let publish =
    Bus.publish
      (Bus.producer bus ~uri:"in-memory://broker.unwatch-bars-command"
         ~serialize:(fun (v : Unwatch_bars_command.t) ->
           Yojson.Safe.to_string (Unwatch_bars_command.yojson_of_t v)))
  in
  fun ~instrument ~timeframe ->
    let cmd : Unwatch_bars_command.t =
      {
        symbol = Instrument.to_qualified instrument;
        timeframe = Timeframe.to_string timeframe;
      }
    in
    publish cmd
