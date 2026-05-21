open Core

include Bar_updated_integration_event_t
include Bar_updated_integration_event_j

let yojson_of_t (v : t) : Yojson.Safe.t = Yojson.Safe.from_string (string_of_t v)
let t_of_yojson (j : Yojson.Safe.t) : t = t_of_string (Yojson.Safe.to_string j)

type domain = Broker_domain.Remote_broker.Events.Remote_bar_updated.t

let of_domain (ev : domain) : t =
  {
    instrument = Instrument_view_model.of_domain ev.instrument;
    timeframe = Timeframe.to_string ev.timeframe;
    candle = Candle_view_model.of_domain ev.candle;
  }
