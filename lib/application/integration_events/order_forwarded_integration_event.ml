type t = {
  client_order_id : string;
  reservation_id : int;
  broker_order : Queries.Order_view_model.t;
}
[@@deriving yojson]

type domain = Domain_event_handlers.Forward_order_to_broker.order_forwarded

let of_domain (ev : domain) : t =
  {
    client_order_id = ev.client_order_id;
    reservation_id = ev.reservation_id;
    broker_order = Queries.Order_view_model.of_domain ev.broker_order;
  }
