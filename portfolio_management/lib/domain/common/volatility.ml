type t = Decimal.t

let zero = Decimal.zero

let of_decimal d =
  if Decimal.is_negative d then
    invalid_arg
      (Printf.sprintf "Volatility.of_decimal: %s — must be >= 0"
         (Decimal.to_string d));
  d

let to_decimal d = d
let equal = Decimal.equal
let compare = Decimal.compare
