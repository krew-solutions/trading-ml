open Core

type t = {
  ts : int64;
  instrument : Instrument_view_model.t;
  action : string;
  strength : float;
  stop_loss : float option;
  take_profit : float option;
  reason : string;
}
[@@deriving yojson]

type domain = Signal.t

let of_domain (s : domain) : t =
  {
    ts = s.ts;
    instrument = Instrument_view_model.of_domain s.instrument;
    action = Signal.action_to_string s.action;
    strength = s.strength;
    stop_loss = Option.map Decimal.to_float s.stop_loss;
    take_profit = Option.map Decimal.to_float s.take_profit;
    reason = s.reason;
  }
