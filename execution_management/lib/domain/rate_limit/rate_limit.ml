module Values = Values

type t = { config : Values.Rate_limit_config.t; recent : float list }

let make ~config = { config; recent = [] }
let config t = t.config

let prune ~window_seconds ~now (xs : float list) : float list =
  let cutoff = now -. window_seconds in
  List.filter (fun ts -> ts >= cutoff) xs

let active_count t ~now =
  List.length
    (prune
       ~window_seconds:(Values.Rate_limit_config.window_seconds t.config)
       ~now t.recent)

let try_acquire t ~now =
  let window = Values.Rate_limit_config.window_seconds t.config in
  let max_orders = Values.Rate_limit_config.max_orders t.config in
  let pruned = prune ~window_seconds:window ~now t.recent in
  if List.length pruned < max_orders then `Allow { t with recent = now :: pruned }
  else `Throttle
