type t = Decimal.t

let of_decimal d =
  if not (Decimal.is_positive d) then
    invalid_arg
      (Printf.sprintf "Hedge_ratio.of_decimal: %s — must be > 0" (Decimal.to_string d));
  d

let to_decimal d = d
let equal = Decimal.equal
let compare = Decimal.compare
