type t = { instrument : Instrument_view_model.t; quantity : string; avg_price : string }
[@@deriving yojson]

type domain = Portfolio_management.Actual_portfolio.Values.Actual_position.t

let of_domain (p : domain) : t =
  {
    instrument = Instrument_view_model.of_domain p.instrument;
    quantity = Decimal.to_string p.quantity;
    avg_price = Decimal.to_string p.avg_price;
  }
