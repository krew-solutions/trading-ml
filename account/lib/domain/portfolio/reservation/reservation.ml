open Core

type t = {
  id : int;
  side : Side.t;
  instrument : Instrument.t;
  cover_qty : Decimal.t;
  open_qty : Decimal.t;
  per_unit_collateral : Decimal.t;
}

let quantity r = Decimal.add r.cover_qty r.open_qty

let reserved_cash r = Decimal.mul r.open_qty r.per_unit_collateral

let reserved_qty r =
  match r.side with
  | Side.Sell -> r.cover_qty
  | Buy -> Decimal.zero

let per_unit_collateral_for_buy ~price ~slippage_buffer ~fee_rate =
  let slip_mult = Decimal.add Decimal.one slippage_buffer in
  Decimal.add (Decimal.mul price slip_mult) (Decimal.mul price fee_rate)

let per_unit_collateral_for_sell_open ~price ~margin_pct = Decimal.mul price margin_pct
