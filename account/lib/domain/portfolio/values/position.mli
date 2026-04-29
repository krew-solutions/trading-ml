(** VO snapshot of an open trading position — instrument, signed quantity,
    VWAP entry price. Identified inside a [Portfolio] aggregate by the
    [instrument] key; carries no separate identity of its own. *)

type t = {
  instrument : Core.Instrument.t;
  quantity : Core.Decimal.t;  (** signed: positive = long, negative = short *)
  avg_price : Core.Decimal.t;  (** VWAP entry price *)
}
