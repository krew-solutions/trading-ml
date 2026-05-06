type t = {
  type_ : string; [@key "type"]
  price : string option;
  stop_price : string option;
  limit_price : string option;
}
[@@deriving yojson]

type domain = Order.kind

let of_domain (k : domain) : t =
  match k with
  | Market -> { type_ = "MARKET"; price = None; stop_price = None; limit_price = None }
  | Limit p ->
      {
        type_ = "LIMIT";
        price = Some (Decimal.to_string p);
        stop_price = None;
        limit_price = None;
      }
  | Stop p ->
      {
        type_ = "STOP";
        price = Some (Decimal.to_string p);
        stop_price = None;
        limit_price = None;
      }
  | Stop_limit { stop; limit } ->
      {
        type_ = "STOP_LIMIT";
        price = None;
        stop_price = Some (Decimal.to_string stop);
        limit_price = Some (Decimal.to_string limit);
      }
