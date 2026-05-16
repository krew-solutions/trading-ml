(** PM-side inbound DTO mirror of an OHLCV candle view model.

    Structural-only: [ts] is an ISO-8601 datetime string
    ([YYYY-MM-DDTHH:MM:SSZ]); OHLCV are decimal strings (bit-exact
    roundtrip with the upstream [Decimal.to_string] form). No
    [of_domain] / [type domain].

    Wire shape regenerated from the producer's .atd contract. *)

include module type of Candle_view_model_t
include module type of Candle_view_model_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t
