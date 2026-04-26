open Core

type t = {
  reservation_id : int;
  side : string;
  instrument : Queries.Instrument_view_model.t;
  quantity : float;
  price : float;
  reserved_cash : float;
}
[@@deriving yojson]

type domain = Engine.Portfolio.amount_reserved

let of_domain (ev : domain) : t =
  {
    reservation_id = ev.reservation_id;
    side = Side.to_string ev.side;
    instrument = Queries.Instrument_view_model.of_domain ev.instrument;
    quantity = Decimal.to_float ev.quantity;
    price = Decimal.to_float ev.price;
    reserved_cash = Decimal.to_float ev.reserved_cash;
  }
