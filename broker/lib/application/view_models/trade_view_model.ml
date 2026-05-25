include Trade_view_model_t
include Trade_view_model_j

let yojson_of_t (v : t) : Yojson.Safe.t = Yojson.Safe.from_string (string_of_t v)
let t_of_yojson (j : Yojson.Safe.t) : t = t_of_string (Yojson.Safe.to_string j)

let of_domain (e : Order.Trade.t) : t =
  {
    trade_id = e.trade_id;
    ts = Datetime.Iso8601.format e.ts;
    quantity = Decimal.to_string e.quantity;
    price = Decimal.to_string e.price;
    fee = Decimal.to_string e.fee;
  }
