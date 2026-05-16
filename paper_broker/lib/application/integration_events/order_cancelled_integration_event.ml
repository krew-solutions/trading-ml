type t = {
  correlation_id : string;
  placement_id : int;
  id : string;
  instrument : Paper_broker_view_models.Instrument_view_model.t;
  cancelled_ts : string;
}
[@@deriving yojson]

type domain = Paper_broker.Order.Events.Order_cancelled.t

let of_domain ~(correlation_id : string) (ev : domain) : t =
  {
    correlation_id;
    placement_id = Paper_broker.Order.Values.Placement_id.to_int ev.placement_id;
    id = ev.id;
    instrument = Paper_broker_view_models.Instrument_view_model.of_domain ev.instrument;
    cancelled_ts = Datetime.Iso8601.format ev.cancelled_ts;
  }
