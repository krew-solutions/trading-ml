(** Configuration for {!Pair_mean_reversion}.

    Carries the construction-policy parameters that govern the
    decision shape — the pair itself, the regression hedge ratio,
    the lookback window, and the entry/exit thresholds. Sizing
    parameters are deliberately {b not} here: capital allocation
    lives in {!Risk_config.risk_budget_fraction}, and the
    qty-from-weight conversion is the job of {!Sizing_policy}.

    Invariants enforced at construction:
    - [window > 0];
    - [|z_entry| > |z_exit|]: the entry threshold must be stricter
      than the exit threshold so that a position opened on a
      z-cross doesn't immediately close on the same bar
      (hysteresis). *)

type t = private {
  book_id : Common.Book_id.t;
  pair : Common.Pair.t;
  hedge_ratio : Common.Hedge_ratio.t;
  window : int;
  z_entry : Common.Z_score.t;
  z_exit : Common.Z_score.t;
}

val make :
  book_id:Common.Book_id.t ->
  pair:Common.Pair.t ->
  hedge_ratio:Common.Hedge_ratio.t ->
  window:int ->
  z_entry:Common.Z_score.t ->
  z_exit:Common.Z_score.t ->
  t
(** Raises [Invalid_argument] on a violation. *)
