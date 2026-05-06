open Core

type t = {
  reservation_id : int;
  side : Side.t;
  instrument : Instrument.t;
  quantity : Decimal.t;
  price : Decimal.t;
  reserved_cash : Decimal.t;
}
