module P = Execution_management.Order_ticket.Placement
module Pv = Execution_management.Order_ticket.Placement.Values

include Placement_view_model_t
include Placement_view_model_j

let yojson_of_t (v : t) : Yojson.Safe.t = Yojson.Safe.from_string (string_of_t v)
let t_of_yojson (j : Yojson.Safe.t) : t = t_of_string (Yojson.Safe.to_string j)

let kind_fields (k : Pv.Order_kind.t) :
    string * string option * string option * string option =
  match k with
  | Market -> ("MARKET", None, None, None)
  | Limit { price } -> ("LIMIT", Some (Decimal.to_string price), None, None)
  | Stop { stop_price } -> ("STOP", None, Some (Decimal.to_string stop_price), None)
  | Stop_limit { stop_price; limit_price } ->
      ( "STOP_LIMIT",
        None,
        Some (Decimal.to_string stop_price),
        Some (Decimal.to_string limit_price) )

let tif_to_string (t : Pv.Tif.t) : string =
  match t with
  | Gtc -> "GTC"
  | Day -> "DAY"
  | Ioc -> "IOC"
  | Fok -> "FOK"

let of_domain (p : P.t) : t =
  let kind_type, kind_price, kind_stop_price, kind_limit_price = kind_fields p.kind in
  {
    placement_id = Pv.Placement_id.to_int p.id;
    requested_quantity = Decimal.to_string p.requested_quantity;
    cumulative_filled = Decimal.to_string p.cumulative_filled;
    remaining_quantity = Decimal.to_string (P.remaining_quantity p);
    status = Pv.Placement_status.to_string p.status;
    kind_type;
    kind_price;
    kind_stop_price;
    kind_limit_price;
    tif = tif_to_string p.tif;
  }
