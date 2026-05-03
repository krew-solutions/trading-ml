type t = float

let of_float x =
  if Float.is_nan x then invalid_arg "Z_score.of_float: NaN";
  if not (Float.is_finite x) then invalid_arg "Z_score.of_float: not finite";
  x

let to_float x = x
let abs = Float.abs
let equal = Float.equal
let compare = Float.compare
