open Core

type t = {
  correlation_id : string;
  id : string;
  client_order_id : string;
  exec_id : string;
  instrument : Paper_broker_queries.Instrument_view_model.t;
  side : string;
  fill_quantity : string;
  fill_price : string;
  fee : string;
  new_total_filled : string;
  fill_ts : string;
}
[@@deriving yojson]

type domain = Paper_broker.Order.Events.Fill_observed.t

let of_domain ~(correlation_id : string) (ev : domain) : t =
  {
    correlation_id;
    id = ev.id;
    client_order_id = ev.client_order_id;
    exec_id = ev.exec_id;
    instrument = Paper_broker_queries.Instrument_view_model.of_domain ev.instrument;
    side = Side.to_string ev.side;
    fill_quantity = Decimal.to_string ev.fill_quantity;
    fill_price = Decimal.to_string ev.fill_price;
    fee = Decimal.to_string ev.fee;
    new_total_filled = Decimal.to_string ev.new_total_filled;
    fill_ts = Datetime.Iso8601.format ev.fill_ts;
  }
