(** Inbound TRADES event: one or more execution legs ("trades"
    in Finam parlance) reported against orders on the
    subscribed account. Multiple {!update}-s for the same
    [order_id] sum to that order's cumulative
    [new_total_filled]; aggregation is the consumer's job —
    Finam ships them per-execution. *)

open Core

type update = {
  trade_id : string;
  order_id : string;
  account_id : string;
  instrument : Instrument.t;
  side : Side.t;
  quantity : Decimal.t;
  price : Decimal.t;
  ts : int64;
}

val parse : Yojson.Safe.t -> update list
(** Returns the batch verbatim; malformed elements are filtered
    out silently (defensive parsing — Finam batches must not
    fail wholesale on one bad leg). *)
