(** Position sizing — what's left of the original [Risk] module after
    extraction. The pre-trade gate ([check] / [decision] / [limits])
    moved to the {!Pre_trade_risk} bounded context; only this
    construction-time helper remains, and even it will move to
    {!Portfolio_management.Sizing} in a follow-up — see plan M3.

    Pure: same inputs → same output. No I/O, no domain dependencies
    beyond {!Decimal}. *)

val size_from_strength :
  equity:Decimal.t ->
  price:Decimal.t ->
  max_position_notional:Decimal.t ->
  strength:float ->
  Decimal.t
(** [size_from_strength ~equity ~price ~max_position_notional ~strength]
    sizes a position from a fraction of equity, clamped by the
    per-instrument notional cap. Returns a positive quantity in lots
    (decimal units). *)
