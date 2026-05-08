(** Position snapshot inside a {!Risk_view.t}: instrument identity, the
    current signed quantity, and the average price at which the
    position was acquired (used as a fallback mark when the pricing
    callback has no quote for the instrument).

    Mirrors the shape that arrives from
    {!Account.Portfolio.Values.Position} via the upstream
    [Position_changed] integration event, but is owned by this BC so
    Risk_view never imports the Account aggregate directly. *)

(*@ function dec_raw (d : Decimal.t) : integer *)
(** Local alias for [Decimal.t]'s scaled-integer projection. See
    [account/portfolio/reservation/reservation.mli] for the rationale —
    Gospel 0.3.1 doesn't carry [model] declarations across files, so
    each consumer restates it. *)

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
(*@ q = quantity p
    ensures dec_raw q = dec_raw p.quantity *)

val avg_price : t -> Decimal.t
(*@ a = avg_price p
    ensures dec_raw a = dec_raw p.avg_price *)
