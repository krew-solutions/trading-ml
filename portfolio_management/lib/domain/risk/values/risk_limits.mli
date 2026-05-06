(** Construction-time risk limits used by {!Risk_policy.clip}. Captures
    the *soft* limits that shape a target proposal as it is built —
    they constrain how big a position the policy is allowed to *want*.

    Hard, gate-keeping limits (kill switch, fat-finger thresholds,
    pre-trade order validation) are a separate concern and live
    outside this BC.

    Invariants enforced at construction:

    - [max_per_instrument_notional ≥ 0];
    - [max_gross_exposure ≥ 0].

    The two caps are otherwise independent: a tight gross cap on top
    of generous per-instrument caps simply means the construction
    pass scales every leg uniformly (see [risk_policy.ml]). *)

type t = private {
  max_per_instrument_notional : Decimal.t;
  max_gross_exposure : Decimal.t;
}

val make : max_per_instrument_notional:Decimal.t -> max_gross_exposure:Decimal.t -> t
(** Raises [Invalid_argument] on a violation. *)

val max_per_instrument_notional : t -> Decimal.t
val max_gross_exposure : t -> Decimal.t
