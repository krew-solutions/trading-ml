(** Outbound projection of
    {!Domain_event_handlers.Forward_order_to_broker.order_forwarded}. *)

type t = {
  client_order_id : string;
  reservation_id : int;
  broker_order : Queries.Order_view_model.t;
}
[@@deriving yojson]

type domain = Domain_event_handlers.Forward_order_to_broker.order_forwarded

val of_domain : domain -> t
