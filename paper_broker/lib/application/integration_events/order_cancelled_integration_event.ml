type t = {
  correlation_id : string;
  id : string;
  client_order_id : string;
  instrument : Paper_broker_queries.Instrument_view_model.t;
  cancelled_ts : string;
}
[@@deriving yojson]

type domain = Paper_broker.Order.Events.Order_cancelled.t

let of_domain ~(correlation_id : string) (ev : domain) : t =
  {
    correlation_id;
    id = ev.id;
    client_order_id = ev.client_order_id;
    instrument = Paper_broker_queries.Instrument_view_model.of_domain ev.instrument;
    cancelled_ts = Datetime.Iso8601.format ev.cancelled_ts;
  }
