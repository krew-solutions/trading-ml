(** Hard pre-trade risk limits used by {!Assessment.assess}. Captures
    the *gatekeeping* limits that veto an order before it leaves the
    process — distinct from the construction-time *soft* limits in
    {!Portfolio_management.Risk_policy} which clip a target proposal.

    Hard-veto semantics: a proposed trade that violates any of these
    limits is rejected; no scaling, no partial accept. The construction
    side may sometimes propose a position the gatekeeper refuses — that
    is the intended division of labour (LEAN's RiskManagementModel,
    Nautilus' RiskEngine).

    Invariants enforced at construction:

    - [min_cash_buffer ≥ 0];
    - [max_gross_exposure ≥ 0];
    - [max_leverage > 0]. *)

type t = private {
  min_cash_buffer : Decimal.t;
      (** The cash floor: post-reservation [cash_after_buffer =
        available_cash − notional] must stay [≥ min_cash_buffer]. A
        zero buffer means cash may be drained to exactly zero. *)
  max_gross_exposure : Decimal.t;
      (** Cap on [Σ |position_qty| × mark + new_notional] across every
        held instrument and the proposed leg. *)
  max_leverage : float;
      (** Cap on [gross_exposure / equity]. Equity is computed
        marked-to-market. *)
}

val make :
  min_cash_buffer:Decimal.t -> max_gross_exposure:Decimal.t -> max_leverage:float -> t
(** Raises [Invalid_argument] on invariant violation. *)

val default : equity:Decimal.t -> t
(** Sensible defaults derived from a starting-equity figure:
    [min_cash_buffer = equity / 20], [max_gross_exposure = equity × 2],
    [max_leverage = 2.0]. Mirrors the original
    [Engine.Risk.default_limits] constants so behaviour at the
    pre-trade gate stays identical to the pre-extraction baseline. *)

val min_cash_buffer : t -> Decimal.t
val max_gross_exposure : t -> Decimal.t
val max_leverage : t -> float
