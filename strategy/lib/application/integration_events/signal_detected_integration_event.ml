type t = {
  strategy_id : string;
  instrument : Queries.Instrument_view_model.t;
  direction : string;
  strength : float;
  price : string;
  reason : string;
  occurred_at : int64;
}
[@@deriving yojson]

type domain = Signal.t

let direction_of_action : Signal.action -> string = function
  | Enter_long | Exit_short -> "UP"
  | Enter_short | Exit_long -> "DOWN"
  | Hold -> "FLAT"

let of_domain ~(strategy_id : string) ~(price : Decimal.t) (s : domain) : t =
  {
    strategy_id;
    instrument = Queries.Instrument_view_model.of_domain s.instrument;
    direction = direction_of_action s.action;
    strength = s.strength;
    price = Decimal.to_string price;
    reason = s.reason;
    occurred_at = s.ts;
  }
