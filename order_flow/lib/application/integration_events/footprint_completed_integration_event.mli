(** Integration event: a footprint bar has sealed for an instrument on a
    given timeframe.

    Published by the order_flow BC when its forming bar rolls over (a
    print arrives for a later bucket) — see ADR 0032. Carries objective
    order-flow facts only: OHLCV reconstructed from the bar's prints, the
    signed [delta], the volume Point of Control, and the per-price
    [clusters]. Thresholded signals (imbalance, CVD divergence) stay in
    the strategy BC, which consumes this event.

    Idempotency: subscribers MUST upsert by (instrument, timeframe,
    open_ts). Repeat publications of the same key (replay, reconnect)
    are part of the contract; ordering / deduplication belong to the
    transport, not the payload.

    DTO-shaped: primitives + nested view models, no domain values. *)

include module type of Footprint_completed_integration_event_t
include module type of Footprint_completed_integration_event_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t

type domain = Order_flow.Footprint.Events.Footprint_completed.t

val of_domain : domain -> t
