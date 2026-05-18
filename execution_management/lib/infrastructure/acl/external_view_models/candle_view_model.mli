(** Wire-format candle (OHLCV bar) — mirror of
    {!Broker.Candle_view_model.t} as seen by EM-side bus
    consumers. Decimals as canonical strings (ADR 0007). *)

include module type of Candle_view_model_t

include module type of Candle_view_model_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t
