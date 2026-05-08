(** Position snapshot inside a {!Risk_view.t}: instrument identity, the
    current signed quantity, and the average price at which the
    position was acquired (used as a fallback mark when the pricing
    callback has no quote for the instrument).

    Mirrors the shape that arrives from
    {!Account.Portfolio.Values.Position} via the upstream
    [Position_changed] integration event, but is owned by this BC so
    Risk_view never imports the Account aggregate directly. *)

type t = private {
  instrument : Core.Instrument.t;
  quantity : Decimal.t;
  avg_price : Decimal.t;
}

val make : instrument:Core.Instrument.t -> quantity:Decimal.t -> avg_price:Decimal.t -> t
(** No invariants beyond non-empty instrument (delegated to
    {!Core.Instrument} smart-ctor). [quantity] may be negative
    (short). [avg_price] is informational; not validated for
    positivity to keep this VO neutral. *)

val instrument : t -> Core.Instrument.t
val quantity : t -> Decimal.t
val avg_price : t -> Decimal.t
