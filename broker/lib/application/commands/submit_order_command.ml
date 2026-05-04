type t = {
  reservation_id : int;
  symbol : string;
  side : string;
  quantity : string;
  kind : Broker_queries.Order_kind_view_model.t;
  tif : string;
}
[@@deriving yojson]
