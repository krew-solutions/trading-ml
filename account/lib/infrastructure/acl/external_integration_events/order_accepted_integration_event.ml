type t = {
  reservation_id : int;
  broker_order : Account_external_view_models.Order_view_model.t;
}
[@@deriving yojson]
