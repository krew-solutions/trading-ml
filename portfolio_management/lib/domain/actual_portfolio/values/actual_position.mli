(** VO snapshot of a held position as PM observes it: instrument,
    signed quantity (positive long / negative short / zero flat),
    VWAP entry price.

    This is PM's own model of the leg, independent of (and projected
    from) [Account.Portfolio.Values.Position.t]. The two share the
    same physical fields but live in different bounded contexts and
    are translated by the inbound ACL adapter. *)

type t = {
  instrument : Core.Instrument.t;
  quantity : Decimal.t;  (** signed: positive = long, negative = short *)
  avg_price : Decimal.t;
}
