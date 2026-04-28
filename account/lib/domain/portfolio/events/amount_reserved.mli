(** Domain Event: a reservation was successfully placed.
    Emitted by [Portfolio.try_reserve] on success. Past-tense name
    per CLAUDE.md "наименование доменного или интеграционного события
    должно содержать глагол прошедшего времени". *)

type t = {
  reservation_id : int;
  side : Core.Side.t;
  instrument : Core.Instrument.t;
  quantity : Core.Decimal.t;
  price : Core.Decimal.t;
  reserved_cash : Core.Decimal.t;
}
