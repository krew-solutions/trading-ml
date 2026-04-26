type t = {
  kind : string;
  client_order_id : string;
  reservation_id : int;
  reason : string;
}
[@@deriving yojson]

type domain = Domain_event_handlers.Forward_order_to_broker.forward_rejection

let of_domain (ev : domain) : t =
  match ev with
  | Order_rejected_by_broker { client_order_id; reservation_id; reason } ->
      { kind = "rejected"; client_order_id; reservation_id; reason }
  | Broker_unreachable { client_order_id; reservation_id; reason } ->
      { kind = "unreachable"; client_order_id; reservation_id; reason }
