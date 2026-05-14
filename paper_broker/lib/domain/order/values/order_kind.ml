type t =
  | Market
  | Limit of Decimal.t
  | Stop of Decimal.t
  | Stop_limit of { stop : Decimal.t; limit : Decimal.t }

let market = Market

let require_positive name d =
  if not (Decimal.is_positive d) then
    invalid_arg
      (Printf.sprintf "Order_kind.%s: %s — must be > 0" name (Decimal.to_string d))

let limit price =
  require_positive "limit" price;
  Limit price

let stop price =
  require_positive "stop" price;
  Stop price

let stop_limit ~stop ~limit =
  require_positive "stop_limit.stop" stop;
  require_positive "stop_limit.limit" limit;
  Stop_limit { stop; limit }
