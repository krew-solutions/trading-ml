open Core

type t = {
  reservation_id : int;
  instrument : Instrument.t;
  side : Side.t;
  filled_quantity : Decimal.t;
  fill_price : Decimal.t;
  fee : Decimal.t;
  new_position_quantity : Decimal.t;
  new_avg_price : Decimal.t;
  new_cash : Decimal.t;
}
