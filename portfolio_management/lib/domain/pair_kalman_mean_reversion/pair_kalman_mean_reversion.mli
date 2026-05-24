(** Cointegrated-pair mean-reversion with {b adaptive} β
    estimated online by a Harrison-West DLM Kalman filter.

    The state-space model treats the pair regression
    [log a_t = α_t + β_t · log b_t + ν_t] as a linear-Gaussian
    DLM with random-walk transition on [(α, β)] and discount-factor
    process noise [C_pred = C / discount] (West & Harrison, *Bayesian
    Forecasting and Dynamic Models*, 1997, §6.3).

    Pipeline per bar:
    1. Cache the log-close per leg. {b Convention}: [y = log A,
       x = log B]; a filter step fires when a [`B] bar arrives
       {i and} the corresponding [`A] log-close is already cached.
    2. The filter step computes the innovation
       [e = y − (α + β · x)] and innovation variance
       [Q = H C_pred Hᵀ + v] with [H = (1, x)], updates the
       posterior via Joseph form (PSD-preserving), and records
       [e] in a Welford running statistic.
    3. While [bars_observed < config.burn_in]: no signal.
    4. Otherwise the innovation z-score
       [z = e / sqrt(max(Q_filter, S_empirical))] is fed through
       the same Flat / Long_spread / Short_spread hysteresis as
       {!Pair_mean_reversion}. The empirical-scale floor
       [max(Q, S_empirical)] hedges the threshold against a
       mis-specified observation noise [v].
    5. On direction change the policy emits a
       {!Construction_intent.Coupled} via {!Pair_intent_builder.build},
       passing [beta = posterior.mean_beta] (clamped below at
       [1e-6] by the builder to absorb transient near-zero
       posteriors). The emitted intent carries
       [Source.Pair_kalman_mean_reversion config.pair] and a
       coupling source label of ["pair_kalman_mean_reversion"]
       so the unified pipeline can distinguish this group from a
       static-policy group at the same timestamp.

    {b One book / one source}: this policy must be authorised
    via [Risk_config.authorises] with
    [Source.Pair_kalman_mean_reversion <pair>]. If an operator
    accidentally configures both static and adaptive policies on
    the same book, only the authorised one's intents are applied;
    the other's are silently dropped by the unified handler. *)

module Values : module type of Values
(** Re-exports of peer subdirs. *)

module Events : module type of Events

include
  Portfolio_construction.S
    with type config = Values.Kalman_dlm_config.t
     and type state = Values.Kalman_dlm_state.t
