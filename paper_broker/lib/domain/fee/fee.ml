module Values = Values

let compute ~(rate : Values.Fee_rate.t) ~(quantity : Decimal.t) ~(price : Decimal.t) :
    Decimal.t =
  let rate_d = Values.Fee_rate.to_decimal rate in
  if Decimal.is_zero rate_d then Decimal.zero
  else Decimal.mul (Decimal.mul quantity price) rate_d
