type t = {
  correlation_id : string;
  placement_id : int;
  broker_order : Broker_view_models.Order_view_model.t;
}
[@@deriving yojson]
