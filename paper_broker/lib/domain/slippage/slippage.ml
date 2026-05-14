module Values = Values
open Core

let apply ~(bps : Values.Slippage_bps.t) (side : Side.t) (price : Decimal.t) : Decimal.t =
  let bps_d = Values.Slippage_bps.to_decimal bps in
  if Decimal.is_zero bps_d then price
  else
    let denom = Decimal.of_int 10_000 in
    let bps_frac = Decimal.div bps_d denom in
    let factor =
      match side with
      | Buy -> Decimal.add Decimal.one bps_frac
      | Sell -> Decimal.sub Decimal.one bps_frac
    in
    Decimal.mul price factor
