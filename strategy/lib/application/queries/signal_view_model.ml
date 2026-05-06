type t = {
  ts : int64;
  instrument : Instrument_view_model.t;
  action : string;
  strength : float;
  stop_loss : string option;
  take_profit : string option;
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
    stop_loss = Option.map Decimal.to_string s.stop_loss;
    take_profit = Option.map Decimal.to_string s.take_profit;
    reason = s.reason;
  }
