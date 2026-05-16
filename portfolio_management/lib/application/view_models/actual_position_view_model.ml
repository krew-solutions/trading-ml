include Actual_position_view_model_t
include Actual_position_view_model_j

let yojson_of_t (v : t) : Yojson.Safe.t = Yojson.Safe.from_string (string_of_t v)
let t_of_yojson (j : Yojson.Safe.t) : t = t_of_string (Yojson.Safe.to_string j)

type domain = Portfolio_management.Actual_portfolio.Values.Actual_position.t

let of_domain (p : domain) : t =
  {
    instrument = Instrument_view_model.of_domain p.instrument;
    quantity = Decimal.to_string p.quantity;
    avg_price = Decimal.to_string p.avg_price;
  }
