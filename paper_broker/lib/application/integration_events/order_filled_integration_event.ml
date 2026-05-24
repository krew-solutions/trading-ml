open Core

include Order_filled_integration_event_t
include Order_filled_integration_event_j

let yojson_of_t (v : t) : Yojson.Safe.t = Yojson.Safe.from_string (string_of_t v)
let t_of_yojson (j : Yojson.Safe.t) : t = t_of_string (Yojson.Safe.to_string j)

type domain = Paper_broker.Order.Events.Order_filled.t

let of_domain ~(correlation_id : string) (ev : domain) : t =
  {
    correlation_id;
    placement_id = Paper_broker.Order.Values.Placement_id.to_int ev.placement_id;
    trade_id = ev.trade_id;
    instrument = Instrument_view_model.of_domain ev.instrument;
    side = Side.to_string ev.side;
    fill_quantity = Decimal.to_string ev.fill_quantity;
    fill_price = Decimal.to_string ev.fill_price;
    fee = Decimal.to_string ev.fee;
    new_total_filled = Decimal.to_string ev.new_total_filled;
    fill_ts = Datetime.Iso8601.format ev.fill_ts;
  }
