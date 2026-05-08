type t = {
  correlation_id : string;
  reservation_id : int;
  broker_order : Execution_management_inbound_queries.Order_view_model.t;
}
[@@deriving yojson]
