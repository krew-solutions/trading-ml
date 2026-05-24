(** Configuration for {!Pair_kalman_mean_reversion} — a Harrison-West
    DLM (West & Harrison, *Bayesian Forecasting and Dynamic Models*,
    2nd ed., 1997, §6.3) treating the pair-regression coefficients
    (α, β) as a slowly-varying hidden state. The operator specifies
    the discount factor for process noise, the observation noise,
    the prior, and the trading thresholds; the filter handles the
    rest.

    All numerical knobs are operator-tunable rather than hardcoded
    because the prior and noise scales are pair-specific economic
    judgements (β ≈ 1 for two oil majors vs. β ≈ 0.3 for a stock
    against its sector basket). Hidden defaults would be load-bearing
    in a Bayesian filter — unacceptable.

    Invariants enforced at construction:
    - [0 < discount < 1] — Harrison-West discount factor on the prior
      covariance: [C_pred = C_prev / discount]. Smaller [discount]
      means faster β-drift; typical daily-bar settings sit near 0.99.
    - [v > 0] — observation noise variance on [log a_t] given
      [(α, β, log b_t)]. Set in units of squared log-price.
    - [|z_entry| > |z_exit|] — hysteresis (entry is stricter than
      exit so positions don't whipsaw at the boundary).
    - [burn_in ≥ 0] — number of paired observations to skip before
      considering any signal.
    - [prior_variance > 0] — applied diagonally to both state
      components [(α, β)] in [C_0].
    - [prior_beta > 0] — matches the pair-trading domain invariant
      that β is strictly positive (mirrors {!Hedge_ratio.t}). *)

type t = private {
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

val make :
  book_id:Common.Book_id.t ->
  pair:Common.Pair.t ->
  discount:Decimal.t ->
  v:Decimal.t ->
  z_entry:Common.Z_score.t ->
  z_exit:Common.Z_score.t ->
  burn_in:int ->
  prior_alpha:Decimal.t ->
  prior_beta:Decimal.t ->
  prior_variance:Decimal.t ->
  t
(** Raises [Invalid_argument] on any invariant violation. *)
