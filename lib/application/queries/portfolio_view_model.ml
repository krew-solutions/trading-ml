open Core

type t = {
  cash : float;
  realized_pnl : float;
  positions : Position_view_model.t list;
  reservations : Reservation_view_model.t list;
}
[@@deriving yojson]

type domain = Account.Portfolio.t

let of_domain (p : domain) : t =
  {
    cash = Decimal.to_float p.cash;
    realized_pnl = Decimal.to_float p.realized_pnl;
    positions = List.map (fun (_, pos) -> Position_view_model.of_domain pos) p.positions;
    reservations = List.map Reservation_view_model.of_domain p.reservations;
  }
