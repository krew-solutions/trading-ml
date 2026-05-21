type t = { ts : int64; bid : Decimal.t; ask : Decimal.t; realised_volatility : float }

let make ~ts ~bid ~ask ~realised_volatility =
  if Decimal.compare bid Decimal.zero <= 0 then
    invalid_arg "Market_data_quote.make: bid must be positive";
  if Decimal.compare ask Decimal.zero <= 0 then
    invalid_arg "Market_data_quote.make: ask must be positive";
  if Decimal.compare bid ask > 0 then
    invalid_arg "Market_data_quote.make: bid must be ≤ ask";
  if realised_volatility < 0.0 then
    invalid_arg "Market_data_quote.make: volatility must be non-negative";
  { ts; bid; ask; realised_volatility }
