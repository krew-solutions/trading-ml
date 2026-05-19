type t =
  | Equity_proportional
  | Volatility_target of { target_annual_vol : Decimal.t }

let equal a b =
  match (a, b) with
  | Equity_proportional, Equity_proportional -> true
  | Volatility_target x, Volatility_target y ->
      Decimal.equal x.target_annual_vol y.target_annual_vol
  | Equity_proportional, _ | Volatility_target _, _ -> false

let name = function
  | Equity_proportional -> "equity_proportional"
  | Volatility_target _ -> "volatility_target"
