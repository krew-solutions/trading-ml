(** JSON encoding for {!Candle.t}, kept separate so [Candle.mli]
    stays Gospel-checkable. *)

val yojson_of_t : Candle.t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> Candle.t

val parse_iso8601 : string -> int64
val of_yojson_flex : Yojson.Safe.t -> Candle.t
