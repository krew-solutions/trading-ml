(** Cointegrated-pair mean-reversion construction policy.

    Maintains a rolling history of synchronised log-spread observations
    over a window of [config.window] bars; computes the z-score of the
    latest spread; emits a target proposal on z-score crossings under
    a hysteresis rule.

    Inputs: candles for the pair's [a]-leg and [b]-leg. Other
    instruments are ignored.

    Hysteresis (modelled in [pair_mr_state]):
    - while [Flat]: open on [|z| ≥ z_entry];
      [z ≥  z_entry] → Short spread (sell A, buy β·B);
      [z ≤ -z_entry] → Long  spread (buy A, sell β·B).
    - while [Long_spread] / [Short_spread]: close on [|z| ≤ z_exit].
    - in the band [z_exit < |z| < z_entry]: no change.

    The target sizing is [notional / mark_a] units of A and
    [β · notional / mark_b] units of B with signs per direction.
    Marks are NOT supplied to the policy — pair_mean_reversion uses
    a simple convention: the target_qty is expressed against the
    candle close prices that triggered the decision. (Risk_policy
    re-clips against marks downstream.)

    NOTE on bar synchronisation: a target proposal is only considered
    after both legs have at least [config.window] samples; the policy
    waits for both rings to fill before emitting anything. *)

module Values : module type of Values
(** Re-exports of peer subdirs. *)

module Events : module type of Events

include
  Portfolio_construction.S
    with type config = Values.Pair_mr_config.t
     and type state = Values.Pair_mr_state.t
