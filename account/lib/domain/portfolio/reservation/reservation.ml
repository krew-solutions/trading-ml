open Core

type t = {
  id : int;
  side : Side.t;
  instrument : Instrument.t;
  quantity : Decimal.t;
  per_unit_cash : Decimal.t;
}

let reserved_cash r = Decimal.mul r.quantity r.per_unit_cash

let reserved_qty r =
  match r.side with
  | Side.Sell -> r.quantity
  | Buy -> Decimal.zero

let per_unit_cash_of ~side ~price ~slippage_buffer ~fee_rate =
  match side with
  | Side.Sell -> Decimal.zero
  | Buy ->
      let slip_mult = Decimal.of_float (1.0 +. slippage_buffer) in
      let fee_mult = Decimal.of_float fee_rate in
      Decimal.add (Decimal.mul price slip_mult) (Decimal.mul price fee_mult)
