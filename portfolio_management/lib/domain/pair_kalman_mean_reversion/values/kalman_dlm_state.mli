(** Internal state of {!Pair_kalman_mean_reversion}: the DLM
    posterior over (α, β) plus the bookkeeping needed to gate
    signals (burn-in, empirical scale of past innovations).

    Posterior covariance is held as the three upper-triangle
    entries of a symmetric 2×2 matrix
    [{c00 = Var(α); c01 = Cov(α, β); c11 = Var(β)}] — this
    representation excludes asymmetry by construction.

    The filter step uses the {b Joseph form} of the covariance
    update,
    {[ C_post = (I − KH) C_pred (I − KH)ᵀ + K v Kᵀ ]}
    which preserves positive semi-definiteness across long
    horizons even under naive floating-point arithmetic. The
    canonical naive form, [C_post = (I − KH) C_pred], drifts
    asymmetric in 64-bit and breaks downstream guarantees.

    Pure value type — every transition returns a fresh [t]. *)

type posterior = private {
  mean_alpha : float;
  mean_beta : float;
  c00 : float;
  c01 : float;
  c11 : float;
}

type innovation_scale = private { sum : float; sum_sq : float; n : int }
(** Welford-style running statistics over past innovations
    [e_t = y_t − F_t θ_t]. The empirical variance hedges
    {!Pair_kalman_mean_reversion}'s innovation z-score against
    a mis-specified observation noise [v]: if the operator's
    [v] understates true noise, the filter's [Q_t] is too
    small and [e/√Q] miscalibrates the hysteresis thresholds;
    [max(Q_filter, S_empirical)] in the z-score denominator
    catches that case within ~20 paired bars. *)

type t

val init : Kalman_dlm_config.t -> t
(** Initial state. Posterior is built from the config priors:
    [mean_alpha = prior_alpha], [mean_beta = prior_beta],
    [c00 = c11 = prior_variance], [c01 = 0]. Innovation scale
    starts empty. *)

val config : t -> Kalman_dlm_config.t
val direction : t -> Common.Pair_direction.t
val posterior : t -> posterior

val bars_observed : t -> int
(** Number of {b paired} (A∧B) observations applied to the
    filter so far. Gates [Kalman_dlm_config.burn_in]. *)

val last_log_close : t -> leg:[ `A | `B ] -> float option

val record_log_close : t -> leg:[ `A | `B ] -> log_close:float -> t
(** Update the per-leg log-close cache. {b Convention}:
    [y = log A, x = log B]. The filter step fires when a [`B]
    bar arrives {i and} [`A] has a cached log-close from an
    earlier (or same-timestamp) bar; an [`A]-only update just
    caches. The step performs:

    1. {b Predict}: [C_pred = C / discount] (Harrison-West).
       State transition is identity: [m_pred = m].
    2. {b Update}: compute innovation [e = y − (α + β·x)],
       innovation variance [Q = H C_pred Hᵀ + v] with
       [H = (1, x)], Kalman gain [K = C_pred Hᵀ / Q],
       posterior mean [m + K·e], and posterior covariance via
       the Joseph form (see module-doc).
    3. Append [e] to [innovation_scale].
    4. Increment [bars_observed]. *)

val current_z : t -> float option
(** Innovation z-score of the latest paired observation.
    Returns [None] while [bars_observed < config.burn_in] or
    when no paired observation has been applied yet.
    Otherwise: [e_last / sqrt(max(Q_filter, S_empirical))]
    where [Q_filter] is the innovation variance from the last
    filter step and [S_empirical] is the Welford-estimated
    variance over all past innovations (or [0] when [n < 2]).
    The [max] is the robustness hedge against a mis-specified
    [v]; in a well-specified filter [Q_filter ≥ S_empirical]
    holds and the floor is observationally irrelevant. *)

val with_direction : t -> Common.Pair_direction.t -> t
