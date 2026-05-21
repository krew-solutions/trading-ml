type t = {
  window : int;
  annualisation_factor : float;
  closes : float array;
  next : int;
  count : int;
}

let init ~window ~annualisation_factor =
  if window < 3 then
    invalid_arg
      (Printf.sprintf
         "Vol_state.init: window must be >= 3 (Bessel-corrected sample stdev needs at \
          least two returns), got %d"
         window);
  if annualisation_factor <= 0.0 then
    invalid_arg
      (Printf.sprintf "Vol_state.init: annualisation_factor must be > 0, got %g"
         annualisation_factor);
  { window; annualisation_factor; closes = Array.make window 0.0; next = 0; count = 0 }

let update s ~close =
  if not (Decimal.is_positive close) then
    invalid_arg
      (Printf.sprintf "Vol_state.update: close must be > 0, got %s"
         (Decimal.to_string close));
  let log_close = log (Decimal.to_float close) in
  let closes = Array.copy s.closes in
  closes.(s.next) <- log_close;
  let next = (s.next + 1) mod s.window in
  let count = if s.count < s.window then s.count + 1 else s.window in
  { s with closes; next; count }

(* Read out the [count] log-closes in chronological order. *)
let chronological s =
  if s.count < s.window then Array.sub s.closes 0 s.count
  else Array.init s.window (fun i -> s.closes.((s.next + i) mod s.window))

let current s =
  if s.count < s.window then None
  else
    let lc = chronological s in
    let n_returns = s.window - 1 in
    let returns = Array.init n_returns (fun i -> lc.(i + 1) -. lc.(i)) in
    let sum = Array.fold_left ( +. ) 0.0 returns in
    let mean = sum /. float_of_int n_returns in
    let sq_dev = Array.fold_left (fun acc r -> acc +. ((r -. mean) ** 2.0)) 0.0 returns in
    (* Sample standard deviation (Bessel's correction) for an
       unbiased estimator on the small windows typical here. *)
    let variance = sq_dev /. float_of_int (n_returns - 1) in
    let sigma = sqrt variance in
    let annualised = sigma *. sqrt s.annualisation_factor in
    Some (Volatility.of_decimal (Decimal.of_float annualised))

let sample_count s = s.count
