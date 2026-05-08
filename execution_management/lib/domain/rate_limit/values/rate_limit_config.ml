type t = { max_orders : int; window_seconds : float }

let make ~max_orders ~window_seconds =
  if max_orders < 0 then invalid_arg "Rate_limit_config.make: max_orders must be >= 0";
  if window_seconds <= 0.0 then
    invalid_arg "Rate_limit_config.make: window_seconds must be > 0";
  { max_orders; window_seconds }

let max_orders t = t.max_orders
let window_seconds t = t.window_seconds
