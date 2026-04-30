open Core

type t = {
  id : int;
  side : string;
  instrument : Instrument_view_model.t;
  quantity : string;
  per_unit_cash : string;
}
[@@deriving yojson]

type domain = Account.Portfolio.Reservation.t

let of_domain (r : domain) : t =
  {
    id = r.id;
    side = Side.to_string r.side;
    instrument = Instrument_view_model.of_domain r.instrument;
    quantity = Decimal.to_string r.quantity;
    per_unit_cash = Decimal.to_string r.per_unit_cash;
  }
