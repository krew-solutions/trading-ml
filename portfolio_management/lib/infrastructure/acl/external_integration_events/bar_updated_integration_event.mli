(** PM-side inbound mirror of the Broker BC's
    {!Broker_integration_events.Bar_updated_integration_event.t}.

    Structurally identical wire shape to the upstream event, but
    owned by PM so its consumer
    ({!Bar_updated_integration_event_handler}, which drives
    pair-mean-reversion policies) listens autonomously without
    importing types across the BC boundary. Wire shape regenerated
    from the producer's .atd contract, so structural drift is
    impossible.

    Idempotency: handlers MUST upsert by
    [(instrument, timeframe, candle.ts)]. Repeat publications of the
    same key (intra-bar updates from the venue, late-subscribe,
    replay, reconnect) are part of the contract.

    Naming: a {b bar} = ({i instrument}, {i timeframe}, {i candle}).
    The {b candle} field holds the pure OHLCV body without context. *)

include module type of Bar_updated_integration_event_t
include module type of Bar_updated_integration_event_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t
