(** In-memory read-model of recently sealed footprints, keyed by
    (qualified symbol, boundary token). Transitional persistence — a
    bounded ring per key feeding the [GET /api/footprints] query, the
    pull-side counterpart to the push-side footprint-completed stream
    (the UI loads recent history here, then subscribes for live seals).

    The boundary token is the same string the integration event carries
    in its [timeframe] field ("M5" for a Time bar, "VOL:<cap>" for a
    Volume bar — ADR 0032 §5), so a caller keys the query by exactly
    what it observes on the wire, without re-deriving the boundary. *)

module Footprint_completed_ie =
  Order_flow_integration_events.Footprint_completed_integration_event

type t

val create : ?cap:int -> unit -> t
(** [cap] bounds the per-key ring (default 500); the oldest footprints
    are dropped once a key exceeds it. *)

val record : t -> Footprint_completed_ie.t -> unit
(** Append a sealed footprint. Idempotent against an immediate
    redelivery — a duplicate carrying the same key and [open_ts] as the
    most recent entry replaces it rather than doubling the head. (The
    contract's full upsert-by-(instrument, timeframe, open_ts) dedup is
    a transport concern; this guards only the common replay case.) *)

val recent :
  t -> symbol:string -> timeframe:string -> n:int -> Footprint_completed_ie.t list
(** The up-to-[n] most recently sealed footprints for [(symbol,
    timeframe)], chronological (oldest-first) like the candle query.
    Empty when the key is unknown. *)
