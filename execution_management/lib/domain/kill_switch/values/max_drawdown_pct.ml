type t = float

let of_float f =
  if f < 0.0 || f > 1.0 then
    invalid_arg (Printf.sprintf "Max_drawdown_pct.of_float: must be in [0,1], got %g" f);
  f

let to_float t = t
let disabled = 0.0
