type t = { n_slices : int; window_seconds : int; start_at : int64 }

let make ~n_slices ~window_seconds ~start_at =
  if n_slices <= 0 then invalid_arg "Twap_params.make: n_slices must be > 0";
  if window_seconds <= 0 then invalid_arg "Twap_params.make: window_seconds must be > 0";
  { n_slices; window_seconds; start_at }
