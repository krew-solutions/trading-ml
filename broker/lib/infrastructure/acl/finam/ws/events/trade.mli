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

val to_domain :
  placement_id:int ->
  new_total_filled:Decimal.t ->
  update ->
  Broker_domain.Remote_broker.Events.Order_filled.t
(** Project a Finam [Trade.update] into the broker's domain event.
    [placement_id] is the caller's reverse-lookup result from the
    venue [order_id]; [new_total_filled] is the caller's
    cumulative-bump result for the leg. [fee] currently defaults
    to zero — Finam's [Trade.update] does not surface per-leg fee
    today; when it does, the field rises into [update] and
    propagates here. *)
