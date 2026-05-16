type t =
  | Market
  | Limit of { price : Decimal.t }
  | Stop of { stop_price : Decimal.t }
  | Stop_limit of { stop_price : Decimal.t; limit_price : Decimal.t }
