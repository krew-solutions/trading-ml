type t = Decimal.t

let of_decimal d =
  if not (Decimal.is_positive d) then
    invalid_arg
      (Printf.sprintf "Participation_rate.of_decimal: %s — must be > 0"
         (Decimal.to_string d));
  if Decimal.compare d Decimal.one > 0 then
    invalid_arg
      (Printf.sprintf "Participation_rate.of_decimal: %s — must be <= 1"
         (Decimal.to_string d));
  d

let to_decimal d = d
let one = Decimal.one
let equal = Decimal.equal
let compare = Decimal.compare
