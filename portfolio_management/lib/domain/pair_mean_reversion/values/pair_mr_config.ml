type t = {
  book_id : Shared.Book_id.t;
  pair : Shared.Pair.t;
  hedge_ratio : Shared.Hedge_ratio.t;
  window : int;
  z_entry : Shared.Z_score.t;
  z_exit : Shared.Z_score.t;
  notional : Decimal.t;
}

let make ~book_id ~pair ~hedge_ratio ~window ~z_entry ~z_exit ~notional =
  if window <= 0 then
    invalid_arg (Printf.sprintf "Pair_mr_config.make: window must be > 0, got %d" window);
  let z_entry_abs = Shared.Z_score.abs z_entry in
  let z_exit_abs = Shared.Z_score.abs z_exit in
  if not (z_entry_abs > z_exit_abs) then
    invalid_arg
      (Printf.sprintf
         "Pair_mr_config.make: |z_entry| (%g) must be > |z_exit| (%g) for hysteresis"
         z_entry_abs z_exit_abs);
  if not (Decimal.is_positive notional) then
    invalid_arg
      (Printf.sprintf "Pair_mr_config.make: notional must be > 0, got %s"
         (Decimal.to_string notional));
  { book_id; pair; hedge_ratio; window; z_entry; z_exit; notional }
