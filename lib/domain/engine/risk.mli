(** Pre-trade risk gate. Pure function over proposed order + current
    portfolio + limits -> accepted order quantity (possibly reduced) or
    rejection reason. *)

open Core

(** Risk limits governing position sizing and exposure. *)
type limits = {
  max_position_notional : Decimal.t;
  max_gross_exposure : Decimal.t;
  max_leverage : float;
  min_cash_buffer : Decimal.t;
}

(** Sensible defaults derived from an initial equity value. *)
val default_limits : equity:Decimal.t -> limits

(** Outcome of a risk check. *)
type decision =
  | Accept of Decimal.t
  | Reject of string

(** Size a position from a signal strength fraction of equity, clamped by
    the per-instrument notional cap. Returns a positive quantity. *)
val size_from_strength :
  equity:Decimal.t ->
  price:Decimal.t ->
  limits:limits ->
  strength:float ->
  Decimal.t

(** [check ~portfolio ~limits ~instrument ~side ~quantity ~price ~mark]
    validates the proposed order against all risk limits. *)
val check :
  portfolio:Portfolio.t ->
  limits:limits ->
  instrument:Instrument.t ->
  side:Side.t ->
  quantity:Decimal.t ->
  price:Decimal.t ->
  mark:(Instrument.t -> Decimal.t option) ->
  decision
