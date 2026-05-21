(** Integration event: an OHLCV bar has been observed for an instrument
    on a given timeframe.

    Published by the broker BC when its upstream venue stream
    delivers a bar (Finam WS / BCS WS).

    Idempotency: subscribers MUST upsert by
    [(instrument, timeframe, candle.ts)]. Repeat publications of the
    same key (intra-bar updates from the venue, late-subscribe,
    replay, reconnect) are part of the contract — the event carries
    no "is this a revision?" flag because such producer-side memory
    is not equivalent to consumer-side delivery state on any non-
    trivial transport. Ordering / deduplication concerns belong to
    the transport layer (e.g. per-key sequence numbers), not the
    payload.

    Naming: a {b bar} = ({i instrument}, {i timeframe}, {i candle}) —
    the contextualised market-data observation. The {b candle} field
    holds the pure OHLCV body without context.

    DTO-shaped: primitives + nested view models, no domain values. *)

include module type of Bar_updated_integration_event_t
include module type of Bar_updated_integration_event_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t

type domain = Broker_domain.Remote_broker.Events.Remote_bar_updated.t

val of_domain : domain -> t
