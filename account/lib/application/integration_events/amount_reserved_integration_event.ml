open Core

type t = {
  reservation_id : int;
  side : string;
  instrument : Queries.Instrument_view_model.t;
  quantity : string;
  price : string;
  reserved_cash : string;
}
[@@deriving yojson]

type domain = Account.Portfolio.Events.Amount_reserved.t

let of_domain (ev : domain) : t =
  {
    reservation_id = ev.reservation_id;
    side = Side.to_string ev.side;
    instrument = Queries.Instrument_view_model.of_domain ev.instrument;
    quantity = Decimal.to_string ev.quantity;
    price = Decimal.to_string ev.price;
    reserved_cash = Decimal.to_string ev.reserved_cash;
  }
