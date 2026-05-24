open Core

type t = {
  reservation_id : int;
  instrument : Instrument.t;
  side : Side.t;
  drawn_quantity : Decimal.t;
  fill_price : Decimal.t;
  fee : Decimal.t;
  remaining_cover_qty : Decimal.t;
  remaining_open_qty : Decimal.t;
  remaining_reserved_cash : Decimal.t;
  new_position_quantity : Decimal.t;
  new_avg_price : Decimal.t;
  new_cash : Decimal.t;
}
