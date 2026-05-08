(** Domain event: {!Risk_view.t} absorbed an upstream position change.

    Telemetry-only: pre_trade_risk does not currently translate this
    event into an outbound integration event. It exists so the
    aggregate's mutating methods follow the project's "every state
    transition emits an event" convention and so future audit / SSE
    consumers can attach without changing the aggregate's signature. *)

type t = {
  book_id : Common.Book_id.t;
  instrument : Core.Instrument.t;
  delta_qty : Decimal.t;
  new_qty : Decimal.t;
  occurred_at : int64;
}

val make :
  book_id:Common.Book_id.t ->
  instrument:Core.Instrument.t ->
  delta_qty:Decimal.t ->
  new_qty:Decimal.t ->
  occurred_at:int64 ->
  t
