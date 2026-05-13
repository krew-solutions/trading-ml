open Core

type t = {
  correlation_id : string;
  reservation_id : int;
  side : string;
  instrument : Account_queries.Instrument_view_model.t;
  quantity : string;
  price : string;
  reserved_cash : string;
}
[@@deriving yojson]

type domain = Account.Portfolio.Events.Amount_reserved.t

let of_domain ~(correlation_id : string) (ev : domain) : t =
  {
    correlation_id;
    reservation_id = ev.reservation_id;
    side = Side.to_string ev.side;
    instrument = Account_queries.Instrument_view_model.of_domain ev.instrument;
    quantity = Decimal.to_string ev.quantity;
    price = Decimal.to_string ev.price;
    reserved_cash = Decimal.to_string ev.reserved_cash;
  }
