(** Unit tests for {!Kalman_dlm_state}: the Joseph-form
    posterior update, the Welford innovation-scale statistic,
    and the burn-in / empirical-floor gating on [current_z]. *)

module Pm = Portfolio_management
module PKM = Pm.Pair_kalman_mean_reversion
module Config = PKM.Values.Kalman_dlm_config
module State = PKM.Values.Kalman_dlm_state

let book = Pm.Common.Book_id.of_string "kalman-book"

let inst sym = Core.Instrument.of_qualified sym

let make_config
    ?(discount = "0.99")
    ?(v = "0.0001")
    ?(z_entry = 2.0)
    ?(z_exit = 0.5)
    ?(burn_in = 0)
    ?(prior_alpha = "0.0")
    ?(prior_beta = "1.0")
    ?(prior_variance = "1.0")
    () =
  let pair = Pm.Common.Pair.make ~a:(inst "SBER@MISX") ~b:(inst "LKOH@MISX") in
  Config.make ~book_id:book ~pair ~discount:(Decimal.of_string discount)
    ~v:(Decimal.of_string v)
    ~z_entry:(Pm.Common.Z_score.of_float z_entry)
    ~z_exit:(Pm.Common.Z_score.of_float z_exit)
    ~burn_in
    ~prior_alpha:(Decimal.of_string prior_alpha)
    ~prior_beta:(Decimal.of_string prior_beta)
    ~prior_variance:(Decimal.of_string prior_variance)

let test_init_from_priors () =
  let cfg = make_config ~prior_alpha:"0.5" ~prior_beta:"1.3" ~prior_variance:"0.25" () in
  let s = State.init cfg in
  let p = State.posterior s in
  Alcotest.(check (float 1e-12)) "alpha prior" 0.5 p.mean_alpha;
  Alcotest.(check (float 1e-12)) "beta prior" 1.3 p.mean_beta;
  Alcotest.(check (float 1e-12)) "c00 prior" 0.25 p.c00;
  Alcotest.(check (float 1e-12)) "c11 prior" 0.25 p.c11;
  Alcotest.(check (float 1e-12)) "c01 init" 0.0 p.c01;
  Alcotest.(check int) "bars_observed zero" 0 (State.bars_observed s);
  Alcotest.(check bool)
    "direction flat" true
    (Pm.Common.Pair_direction.equal (State.direction s) Pm.Common.Pair_direction.Flat)

let test_a_only_update_does_not_advance_filter () =
  let s = State.init (make_config ()) in
  let s' = State.record_log_close s ~leg:`A ~log_close:(log 100.0) in
  Alcotest.(check int) "bars_observed still zero" 0 (State.bars_observed s');
  Alcotest.(check (option (float 1e-12))) "no z yet" None (State.current_z s')

let test_b_without_a_does_not_step () =
  let s = State.init (make_config ()) in
  let s' = State.record_log_close s ~leg:`B ~log_close:(log 50.0) in
  Alcotest.(check int) "bars_observed still zero" 0 (State.bars_observed s');
  Alcotest.(check (option (float 1e-12))) "no z yet" None (State.current_z s')

let test_first_paired_step_increments_bars () =
  let s = State.init (make_config ()) in
  let s = State.record_log_close s ~leg:`A ~log_close:(log 100.0) in
  let s = State.record_log_close s ~leg:`B ~log_close:(log 100.0) in
  Alcotest.(check int) "bars_observed one" 1 (State.bars_observed s)

(* Deterministic LCG to produce reproducible noise without
   pulling in qcheck. Seed is the test's responsibility. *)
type rng = { mutable s : int64 }

let rng_create seed = { s = Int64.of_int seed }

let rng_next_float r =
  (* xorshift64; map to [-1, 1) *)
  let x = r.s in
  let x = Int64.logxor x (Int64.shift_left x 13) in
  let x = Int64.logxor x (Int64.shift_right_logical x 7) in
  let x = Int64.logxor x (Int64.shift_left x 17) in
  r.s <- x;
  let u = Int64.to_float (Int64.shift_right_logical x 12) /. 1.7592186044416e13 in
  (* u ∈ [0, 1); map to [-1, 1) *)
  (u *. 2.0) -. 1.0

(* Drive [n] synthetic paired bars through the filter with
   log_b ~ random walk and log_a = α_true + β_true · log_b + N(0, σ²),
   then return (final_state, list of (c00, c11, c01) post-step). *)
let drive_synthetic ~n ~beta_true ~alpha_true ~sigma_obs ~seed cfg =
  let rng = rng_create seed in
  let log_b = ref (log 100.0) in
  let s = ref (State.init cfg) in
  let snaps = ref [] in
  for _ = 1 to n do
    (* Random-walk log_b *)
    log_b := !log_b +. (0.005 *. rng_next_float rng);
    let noise = sigma_obs *. rng_next_float rng in
    let log_a = alpha_true +. (beta_true *. !log_b) +. noise in
    s := State.record_log_close !s ~leg:`A ~log_close:log_a;
    s := State.record_log_close !s ~leg:`B ~log_close:!log_b;
    let p = State.posterior !s in
    snaps := (p.c00, p.c11, p.c01) :: !snaps
  done;
  (!s, List.rev !snaps)

let test_kalman_update_psd_invariant () =
  (* PSD for symmetric 2x2: c00 ≥ 0, c11 ≥ 0, det = c00·c11 − c01² ≥ 0.
     We feed 1000 synthetic bars and assert every snapshot is PSD
     within a small floating-point tolerance. *)
  let cfg = make_config ~prior_variance:"0.5" ~v:"0.0004" () in
  let _, snaps =
    drive_synthetic ~n:1000 ~beta_true:1.3 ~alpha_true:0.5 ~sigma_obs:0.02 ~seed:42 cfg
  in
  let tol = 1e-12 in
  let bad =
    List.fold_left
      (fun acc (c00, c11, c01) ->
        let det = (c00 *. c11) -. (c01 *. c01) in
        if c00 < -.tol || c11 < -.tol || det < -.tol then acc + 1 else acc)
      0 snaps
  in
  Alcotest.(check int) "no PSD violation across 1000 steps" 0 bad

let test_kalman_beta_converges () =
  (* β_true = 1.3; with v = 0.0004 (σ_obs ≈ 0.02) and 500 paired
     bars, the posterior mean should be within 0.1 of the truth
     (loose threshold — this is a behavioural sanity check, not a
     statistical efficiency bound). *)
  let cfg =
    make_config ~prior_alpha:"0.0" ~prior_beta:"1.0" ~prior_variance:"1.0" ~v:"0.0004"
      ~discount:"0.999" ()
  in
  let s_final, _ =
    drive_synthetic ~n:500 ~beta_true:1.3 ~alpha_true:0.5 ~sigma_obs:0.02 ~seed:7 cfg
  in
  let beta_est = (State.posterior s_final).mean_beta in
  Alcotest.(check bool)
    (Printf.sprintf "|beta_est (%g) - 1.3| < 0.1" beta_est)
    true
    (Float.abs (beta_est -. 1.3) < 0.1)

let test_burn_in_gates_current_z () =
  let cfg = make_config ~burn_in:5 () in
  let s = ref (State.init cfg) in
  (* Feed 4 paired observations — burn-in not yet exhausted *)
  for k = 1 to 4 do
    let lb = log (100.0 +. float_of_int k) in
    let la = log (100.0 +. float_of_int k) in
    s := State.record_log_close !s ~leg:`A ~log_close:la;
    s := State.record_log_close !s ~leg:`B ~log_close:lb
  done;
  Alcotest.(check (option (float 1e-12)))
    "z is None before burn_in completes" None (State.current_z !s);
  (* 5th paired observation completes burn_in *)
  s := State.record_log_close !s ~leg:`A ~log_close:(log 105.0);
  s := State.record_log_close !s ~leg:`B ~log_close:(log 105.0);
  Alcotest.(check bool)
    "z is Some after burn_in" true
    (Option.is_some (State.current_z !s))

let test_empirical_floor_when_v_understated () =
  (* If the operator sets v far below the true innovation
     variance, |Q_filter| collapses and naive z would blow up;
     the empirical scale floor catches that within a handful
     of bars. We construct a scenario where σ_obs = 0.1
     (S_empirical ≈ 0.01) but config.v = 1e-8 (the smallest
     representable positive Decimal at scale=8 — well below
     S_empirical) and assert that |current_z| stays in a sane
     range (< 10) after the filter has seen enough innovations
     to populate Welford. *)
  let cfg = make_config ~v:"0.00000001" ~burn_in:10 () in
  let s = ref (State.init cfg) in
  let rng = rng_create 1234 in
  for _ = 1 to 100 do
    let lb = log (100.0 +. (10.0 *. rng_next_float rng)) in
    let la = (1.3 *. lb) +. (0.1 *. rng_next_float rng) in
    s := State.record_log_close !s ~leg:`A ~log_close:la;
    s := State.record_log_close !s ~leg:`B ~log_close:lb
  done;
  match State.current_z !s with
  | None -> Alcotest.fail "expected Some z after 100 paired bars past burn_in"
  | Some z ->
      Alcotest.(check bool)
        (Printf.sprintf "|z| (%g) stays bounded by empirical scale floor even with tiny v"
           z)
        true
        (Float.abs z < 10.0)

let tests =
  [
    Alcotest.test_case "init builds posterior from priors" `Quick test_init_from_priors;
    Alcotest.test_case "A-only update does not advance filter" `Quick
      test_a_only_update_does_not_advance_filter;
    Alcotest.test_case "B without cached A does not step" `Quick
      test_b_without_a_does_not_step;
    Alcotest.test_case "first paired step increments bars_observed" `Quick
      test_first_paired_step_increments_bars;
    Alcotest.test_case "Joseph-form covariance stays PSD across 1000 bars" `Quick
      test_kalman_update_psd_invariant;
    Alcotest.test_case "posterior β converges toward truth on synthetic data" `Quick
      test_kalman_beta_converges;
    Alcotest.test_case "burn_in gates current_z" `Quick test_burn_in_gates_current_z;
    Alcotest.test_case "empirical scale floor catches understated v" `Quick
      test_empirical_floor_when_v_understated;
  ]
