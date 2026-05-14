(** Domain event: {!Risk_view.t} absorbed a fill — both the new cash
    balance and the new per-instrument position state — atomically,
    from a single upstream [Reservation_filled_integration_event].

    Past-tense name; pure data carrier. The atomic shape (single
    event for both fields) preserves the [equity = cash +
    Σ qty × mark] invariant across consumer observation.

    Telemetry-only: pre_trade_risk does not translate this event
    into an outbound integration event. It exists so the aggregate's
    mutating method follows the project's "every state transition
    emits an event" convention. *)

type t = {
  book_id : Common.Book_id.t;
  instrument : Core.Instrument.t;
  new_position_quantity : Decimal.t;
  new_avg_price : Decimal.t;
  new_cash : Decimal.t;
  occurred_at : int64;
}

val make :
  book_id:Common.Book_id.t ->
  instrument:Core.Instrument.t ->
  new_position_quantity:Decimal.t ->
  new_avg_price:Decimal.t ->
  new_cash:Decimal.t ->
  occurred_at:int64 ->
  t
