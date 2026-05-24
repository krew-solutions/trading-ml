type t = {
  book_id : Common.Book_id.t;
  pair : Common.Pair.t;
  discount : Decimal.t;
  v : Decimal.t;
  z_entry : Common.Z_score.t;
  z_exit : Common.Z_score.t;
  burn_in : int;
  prior_alpha : Decimal.t;
  prior_beta : Decimal.t;
  prior_variance : Decimal.t;
}

let make
    ~book_id
    ~pair
    ~discount
    ~v
    ~z_entry
    ~z_exit
    ~burn_in
    ~prior_alpha
    ~prior_beta
    ~prior_variance =
  if (not (Decimal.is_positive discount)) || Decimal.compare discount Decimal.one >= 0
  then
    invalid_arg
      (Printf.sprintf "Kalman_dlm_config.make: discount must be in (0, 1), got %s"
         (Decimal.to_string discount));
  if not (Decimal.is_positive v) then
    invalid_arg
      (Printf.sprintf "Kalman_dlm_config.make: v must be > 0, got %s"
         (Decimal.to_string v));
  let z_entry_abs = Common.Z_score.abs z_entry in
  let z_exit_abs = Common.Z_score.abs z_exit in
  if not (z_entry_abs > z_exit_abs) then
    invalid_arg
      (Printf.sprintf
         "Kalman_dlm_config.make: |z_entry| (%g) must be > |z_exit| (%g) for hysteresis"
         z_entry_abs z_exit_abs);
  if burn_in < 0 then
    invalid_arg
      (Printf.sprintf "Kalman_dlm_config.make: burn_in must be >= 0, got %d" burn_in);
  if not (Decimal.is_positive prior_variance) then
    invalid_arg
      (Printf.sprintf "Kalman_dlm_config.make: prior_variance must be > 0, got %s"
         (Decimal.to_string prior_variance));
  if not (Decimal.is_positive prior_beta) then
    invalid_arg
      (Printf.sprintf "Kalman_dlm_config.make: prior_beta must be > 0, got %s"
         (Decimal.to_string prior_beta));
  {
    book_id;
    pair;
    discount;
    v;
    z_entry;
    z_exit;
    burn_in;
    prior_alpha;
    prior_beta;
    prior_variance;
  }
