type t = {
  reservation_id : int;
  symbol : string;
  side : string;
  quantity : float;
  kind : Queries.Order_kind_view_model.t;
  tif : string;
}
[@@deriving yojson]
