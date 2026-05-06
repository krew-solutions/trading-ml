type t = { max_per_instrument_notional : Decimal.t; max_gross_exposure : Decimal.t }

let make ~max_per_instrument_notional ~max_gross_exposure =
  if Decimal.is_negative max_per_instrument_notional then
    invalid_arg "Risk_limits.make: max_per_instrument_notional must be >= 0";
  if Decimal.is_negative max_gross_exposure then
    invalid_arg "Risk_limits.make: max_gross_exposure must be >= 0";
  { max_per_instrument_notional; max_gross_exposure }

let max_per_instrument_notional t = t.max_per_instrument_notional
let max_gross_exposure t = t.max_gross_exposure
