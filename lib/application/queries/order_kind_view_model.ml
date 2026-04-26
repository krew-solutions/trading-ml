open Core

type t = {
  type_ : string; [@key "type"]
  price : float option;
  stop_price : float option;
  limit_price : float option;
}
[@@deriving yojson]

type domain = Order.kind

let of_domain (k : domain) : t =
  match k with
  | Market -> { type_ = "MARKET"; price = None; stop_price = None; limit_price = None }
  | Limit p ->
      {
        type_ = "LIMIT";
        price = Some (Decimal.to_float p);
        stop_price = None;
        limit_price = None;
      }
  | Stop p ->
      {
        type_ = "STOP";
        price = Some (Decimal.to_float p);
        stop_price = None;
        limit_price = None;
      }
  | Stop_limit { stop; limit } ->
      {
        type_ = "STOP_LIMIT";
        price = None;
        stop_price = Some (Decimal.to_float stop);
        limit_price = Some (Decimal.to_float limit);
      }
