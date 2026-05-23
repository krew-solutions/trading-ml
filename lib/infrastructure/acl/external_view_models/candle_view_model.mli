(** Server-side inbound DTO mirror of an OHLCV candle view model.

    Structural fields lifted from the wire: [ts] is an ISO-8601
    datetime string ([YYYY-MM-DDTHH:MM:SSZ]); OHLCV are decimal
    strings (bit-exact roundtrip with the upstream
    [Decimal.to_string] form). The [to_domain] projection
    reassembles the local [Core.Candle.t] via
    [Datetime.Iso8601.parse] for the timestamp and
    [Decimal.of_string] for each numeric field. Malformed input
    raises; the caller wraps in [try _ with _ -> ...] and drops
    the payload with a warn log.

    No [of_domain] / outbound direction: this DTO is consumed
    (deserialized from an upstream BC's outbound JSON), not
    produced from a server domain value.

    Wire shape regenerated from the producer's .atd contract. *)

include module type of Candle_view_model_t
include module type of Candle_view_model_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t

type domain = Core.Candle.t

val to_domain : t -> domain
(** Reconstruct the local domain value from the wire DTO. Raises
    if [ts] is not a parseable ISO-8601 timestamp or any OHLCV
    string is not a parseable decimal. *)
