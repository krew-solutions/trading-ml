(** Domain event: {!Risk_view.t} absorbed an upstream cash change.

    Telemetry-only — same rationale as {!Position_recorded}. *)

type t = {
  book_id : Common.Book_id.t;
  delta : Decimal.t;
  new_balance : Decimal.t;
  occurred_at : int64;
}

val make :
  book_id:Common.Book_id.t ->
  delta:Decimal.t ->
  new_balance:Decimal.t ->
  occurred_at:int64 ->
  t
