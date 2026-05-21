type t = {
  n_slices : int;
  window_seconds : int;
  start_at : int64;
  volume_profile : float list;
}

let make ~n_slices ~window_seconds ~start_at ~volume_profile =
  if n_slices <= 0 then invalid_arg "Vwap_params.make: n_slices must be > 0";
  if window_seconds <= 0 then invalid_arg "Vwap_params.make: window_seconds must be > 0";
  if List.length volume_profile <> n_slices then
    invalid_arg "Vwap_params.make: volume_profile length must equal n_slices";
  if List.exists (fun w -> w < 0.0) volume_profile then
    invalid_arg "Vwap_params.make: weights must be non-negative";
  let sum = List.fold_left ( +. ) 0.0 volume_profile in
  if sum <= 0.0 then invalid_arg "Vwap_params.make: weights must sum to a positive value";
  let normalised = List.map (fun w -> w /. sum) volume_profile in
  { n_slices; window_seconds; start_at; volume_profile = normalised }
