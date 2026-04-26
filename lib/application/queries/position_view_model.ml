open Core

type t = { instrument : Instrument_view_model.t; quantity : float; avg_price : float }
[@@deriving yojson]

type domain = Engine.Portfolio.position

let of_domain (p : domain) : t =
  {
    instrument = Instrument_view_model.of_domain p.instrument;
    quantity = Decimal.to_float p.quantity;
    avg_price = Decimal.to_float p.avg_price;
  }
