type t = Decimal.t

let zero = Decimal.zero
let one = Decimal.one

let of_decimal d =
  if Decimal.is_negative d || Decimal.compare d Decimal.one > 0 then
    invalid_arg
      (Printf.sprintf "Strength.of_decimal: %s — must lie in [0, 1]" (Decimal.to_string d));
  d

let to_decimal d = d
let of_float f = of_decimal (Decimal.of_float f)
let equal = Decimal.equal
let compare = Decimal.compare
