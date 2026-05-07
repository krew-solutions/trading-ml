type t = {
  reservation_id : int;
  broker_order : Account_inbound_queries.Order_view_model.t;
}
[@@deriving yojson]
