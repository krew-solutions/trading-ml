let size_from_strength
    ~(equity : Decimal.t)
    ~(price : Decimal.t)
    ~(max_position_notional : Decimal.t)
    ~(strength : float) : Decimal.t =
  let f = Float.max 0.0 (Float.min 1.0 strength) in
  let budget = Decimal.mul equity (Decimal.of_float f) in
  let budget = Decimal.min budget max_position_notional in
  if Decimal.is_zero price then Decimal.zero else Decimal.div budget price
