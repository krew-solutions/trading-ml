type t = Decimal.t

let of_decimal d =
  if Decimal.is_negative d then
    invalid_arg
      (Printf.sprintf "Slippage_bps.of_decimal: %s — must be >= 0" (Decimal.to_string d));
  d

let to_decimal d = d
let zero = Decimal.zero
let equal = Decimal.equal
let compare = Decimal.compare
