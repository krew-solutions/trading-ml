open Core

include Trade_executed_integration_event_t
include Trade_executed_integration_event_j

let yojson_of_t (v : t) : Yojson.Safe.t = Yojson.Safe.from_string (string_of_t v)
let t_of_yojson (j : Yojson.Safe.t) : t = t_of_string (Yojson.Safe.to_string j)

type domain = Paper_broker.Order.Events.Trade_executed.t

let of_domain ~(correlation_id : string) (ev : domain) : t =
  {
    correlation_id;
    placement_id = Paper_broker.Order.Values.Placement_id.to_int ev.placement_id;
    trade_id = ev.trade_id;
    instrument = Instrument_view_model.of_domain ev.instrument;
    side = Side.to_string ev.side;
    quantity = Decimal.to_string ev.quantity;
    price = Decimal.to_string ev.price;
    fee = Decimal.to_string ev.fee;
    ts = Datetime.Iso8601.format ev.ts;
  }
