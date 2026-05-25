(** Inbound TRADES event: one or more execution legs ("trades"
    in Finam parlance) reported against orders on the
    subscribed account. Finam ships them per-execution;
    aggregation into a placement's running total is the
    consuming aggregate's job, not the broker's. *)

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
  placement_id:int -> update -> Broker_domain.Remote_broker.Events.Trade_executed.t
(** Project a Finam [Trade.update] into the broker's domain event.
    [placement_id] is the caller's reverse-lookup result from the
    venue [order_id]. [fee] currently defaults to zero — Finam's
    [Trade.update] does not surface per-leg fee today; when it
    does, the field rises into [update] and propagates here. *)
