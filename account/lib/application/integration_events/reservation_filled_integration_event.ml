open Core

type t = {
  correlation_id : string;
  reservation_id : int;
  instrument : Account_view_models.Instrument_view_model.t;
  side : string;
  filled_quantity : string;
  fill_price : string;
  fee : string;
  new_position_quantity : string;
  new_avg_price : string;
  new_cash : string;
}
[@@deriving yojson]

type domain = Account.Portfolio.Events.Reservation_filled.t

let of_domain ~(correlation_id : string) (ev : domain) : t =
  {
    correlation_id;
    reservation_id = ev.reservation_id;
    instrument = Account_view_models.Instrument_view_model.of_domain ev.instrument;
    side = Side.to_string ev.side;
    filled_quantity = Decimal.to_string ev.filled_quantity;
    fill_price = Decimal.to_string ev.fill_price;
    fee = Decimal.to_string ev.fee;
    new_position_quantity = Decimal.to_string ev.new_position_quantity;
    new_avg_price = Decimal.to_string ev.new_avg_price;
    new_cash = Decimal.to_string ev.new_cash;
  }
