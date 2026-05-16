(** paper_broker-side inbound mirror of the Broker BC's
    [Bar_updated_integration_event.t].

    Structurally identical wire shape to the upstream event, but
    owned by paper_broker so its consumer
    ({!Bar_updated_integration_event_handler}) listens
    autonomously without importing types across the BC boundary.
    Wire shape regenerated from the producer's .atd contract, so
    structural drift is impossible — dune rebuilds the consumer
    side from the same source of truth as the upstream emitter.

    Naming: a {b bar} = ({i instrument}, {i timeframe}, {i candle}).
    The {b candle} field holds the pure OHLCV body without
    context. *)

include module type of Bar_updated_integration_event_t
include module type of Bar_updated_integration_event_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t
