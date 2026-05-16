type t = {
  correlation_id : string;
  placement_id : int;
  symbol : string;
  side : string;
  quantity : string;
  kind : Paper_broker_view_models.Order_kind_view_model.t;
  tif : string;
}
[@@deriving yojson]
