type posterior = {
  mean_alpha : float;
  mean_beta : float;
  c00 : float;
  c01 : float;
  c11 : float;
}

type innovation_scale = { sum : float; sum_sq : float; n : int }

type last_step = { e : float; q : float }
(** Last filter step's innovation and innovation-variance. [None]
    until the first paired observation has been applied. *)

type t = {
  config : Kalman_dlm_config.t;
  direction : Common.Pair_direction.t;
  posterior : posterior;
  innovation_scale : innovation_scale;
  last_step : last_step option;
  last_a_log_close : float option;
  last_b_log_close : float option;
  bars_observed : int;
}

let init (config : Kalman_dlm_config.t) =
  let prior_variance = Decimal.to_float config.prior_variance in
  let posterior =
    {
      mean_alpha = Decimal.to_float config.prior_alpha;
      mean_beta = Decimal.to_float config.prior_beta;
      c00 = prior_variance;
      c01 = 0.0;
      c11 = prior_variance;
    }
  in
  {
    config;
    direction = Common.Pair_direction.Flat;
    posterior;
    innovation_scale = { sum = 0.0; sum_sq = 0.0; n = 0 };
    last_step = None;
    last_a_log_close = None;
    last_b_log_close = None;
    bars_observed = 0;
  }

let config s = s.config
let direction s = s.direction
let posterior s = s.posterior
let bars_observed s = s.bars_observed

let last_log_close s ~leg =
  match leg with
  | `A -> s.last_a_log_close
  | `B -> s.last_b_log_close

let with_direction s direction = { s with direction }

let welford_update sc ~e =
  { sum = sc.sum +. e; sum_sq = sc.sum_sq +. (e *. e); n = sc.n + 1 }

let welford_variance sc =
  if sc.n < 2 then 0.0
  else
    let n = float_of_int sc.n in
    let mean = sc.sum /. n in
    let var = (sc.sum_sq /. n) -. (mean *. mean) in
    if var < 0.0 then 0.0 else var

(* Kalman predict + update for the scalar-observation DLM
   y_t = α_t + β_t · x_t + ν_t,  ν_t ~ N(0, v)
   (α_t, β_t) = (α_{t-1}, β_{t-1}) + ω_t,    ω_t ~ N(0, W_t)
   with W_t supplied implicitly via Harrison-West discount:
   C_pred = C / δ. Posterior covariance via Joseph form. *)
let kalman_step ~discount ~v (p : posterior) ~x ~y : posterior * float * float =
  (* Predict *)
  let c00_pred = p.c00 /. discount in
  let c01_pred = p.c01 /. discount in
  let c11_pred = p.c11 /. discount in
  (* Observation row H = (1, x) *)
  let h0 = 1.0 in
  let h1 = x in
  (* Innovation variance Q = H C_pred Hᵀ + v *)
  let q =
    (h0 *. h0 *. c00_pred) +. (2.0 *. h0 *. h1 *. c01_pred) +. (h1 *. h1 *. c11_pred) +. v
  in
  (* Kalman gain K = C_pred Hᵀ / Q *)
  let k0 = ((h0 *. c00_pred) +. (h1 *. c01_pred)) /. q in
  let k1 = ((h0 *. c01_pred) +. (h1 *. c11_pred)) /. q in
  (* Innovation e = y − H · m_pred  (m_pred = m, identity transition) *)
  let e = y -. ((p.mean_alpha *. h0) +. (p.mean_beta *. h1)) in
  let m0' = p.mean_alpha +. (k0 *. e) in
  let m1' = p.mean_beta +. (k1 *. e) in
  (* Joseph form: P' = (I − KH) P_pred (I − KH)ᵀ + K v Kᵀ.
     For scalar observation, K v Kᵀ = v · K Kᵀ.
     Let I − KH = [[i00 i01]; [i10 i11]]. *)
  let i00 = 1.0 -. (k0 *. h0) in
  let i01 = -.(k0 *. h1) in
  let i10 = -.(k1 *. h0) in
  let i11 = 1.0 -. (k1 *. h1) in
  (* M = (I − KH) · C_pred  (2×2 product, C_pred symmetric) *)
  let m00 = (i00 *. c00_pred) +. (i01 *. c01_pred) in
  let m01 = (i00 *. c01_pred) +. (i01 *. c11_pred) in
  let m10 = (i10 *. c00_pred) +. (i11 *. c01_pred) in
  let m11 = (i10 *. c01_pred) +. (i11 *. c11_pred) in
  (* C' = M · (I − KH)ᵀ + v K Kᵀ *)
  let c00' = (m00 *. i00) +. (m01 *. i01) +. (v *. k0 *. k0) in
  let c01' = (m00 *. i10) +. (m01 *. i11) +. (v *. k0 *. k1) in
  let c11' = (m10 *. i10) +. (m11 *. i11) +. (v *. k1 *. k1) in
  ({ mean_alpha = m0'; mean_beta = m1'; c00 = c00'; c01 = c01'; c11 = c11' }, e, q)

let record_log_close s ~leg ~log_close =
  let s' =
    match leg with
    | `A -> { s with last_a_log_close = Some log_close }
    | `B -> { s with last_b_log_close = Some log_close }
  in
  match leg with
  | `A ->
      (* A-only updates just cache the observation; the filter
         step is driven by B arrivals (y = log A, x = log B). *)
      s'
  | `B -> (
      match s'.last_a_log_close with
      | None ->
          (* B arrived before any A — nothing to regress against. *)
          s'
      | Some la ->
          let discount = Decimal.to_float s'.config.discount in
          let v = Decimal.to_float s'.config.v in
          let posterior', e, q =
            kalman_step ~discount ~v s'.posterior ~x:log_close ~y:la
          in
          {
            s' with
            posterior = posterior';
            innovation_scale = welford_update s'.innovation_scale ~e;
            last_step = Some { e; q };
            bars_observed = s'.bars_observed + 1;
          })

let current_z s =
  if s.bars_observed < s.config.burn_in then None
  else
    match s.last_step with
    | None -> None
    | Some { e; q } ->
        let s_emp = welford_variance s.innovation_scale in
        let denom_sq = if s_emp > q then s_emp else q in
        if denom_sq <= 0.0 then None else Some (e /. sqrt denom_sq)
