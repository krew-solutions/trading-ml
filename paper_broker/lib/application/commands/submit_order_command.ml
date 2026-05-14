type t = {
  correlation_id : string;
  reservation_id : int;
  symbol : string;
  side : string;
  quantity : string;
  kind : Paper_broker_queries.Order_kind_view_model.t;
  tif : string;
}
[@@deriving yojson]
