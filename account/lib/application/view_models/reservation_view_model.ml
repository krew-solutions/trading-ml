open Core

type t = {
  id : int;
  side : string;
  instrument : Instrument_view_model.t;
  cover_qty : string;
  open_qty : string;
  per_unit_collateral : string;
}
[@@deriving yojson]

type domain = Account.Portfolio.Reservation.t

let of_domain (r : domain) : t =
  {
    id = r.id;
    side = Side.to_string r.side;
    instrument = Instrument_view_model.of_domain r.instrument;
    cover_qty = Decimal.to_string r.cover_qty;
    open_qty = Decimal.to_string r.open_qty;
    per_unit_collateral = Decimal.to_string r.per_unit_collateral;
  }
