open Core

type t = {
  correlation_id : string;
  id : string;
  client_order_id : string;
  instrument : Paper_broker_queries.Instrument_view_model.t;
  side : string;
  quantity : string;
  created_ts : string;
}
[@@deriving yojson]

type domain = Paper_broker.Order.Events.Order_accepted.t

let of_domain ~(correlation_id : string) (ev : domain) : t =
  {
    correlation_id;
    id = ev.id;
    client_order_id = ev.client_order_id;
    instrument = Paper_broker_queries.Instrument_view_model.of_domain ev.instrument;
    side = Side.to_string ev.side;
    quantity = Decimal.to_string ev.quantity;
    created_ts = Datetime.Iso8601.format ev.created_ts;
  }
