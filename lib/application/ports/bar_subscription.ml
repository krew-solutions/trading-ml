open Core

type t = {
  watch : instrument:Instrument.t -> timeframe:Timeframe.t -> unit;
  unwatch : instrument:Instrument.t -> timeframe:Timeframe.t -> unit;
}

let noop : t =
  {
    watch = (fun ~instrument:_ ~timeframe:_ -> ());
    unwatch = (fun ~instrument:_ ~timeframe:_ -> ());
  }
