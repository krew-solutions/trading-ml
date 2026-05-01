(** Domain Event: a reservation was successfully placed.
    Emitted by [Portfolio.try_reserve] on success. The past-tense
    name follows the project convention that domain and integration
    events are named with a past-tense verb (a fact about what
    happened), in contrast to commands which take an imperative. *)

type t = {
  reservation_id : int;
  side : Core.Side.t;
  instrument : Core.Instrument.t;
  quantity : Decimal.t;
  price : Decimal.t;
  reserved_cash : Decimal.t;
}
