(** Server-side outbound DTO mirror of {b broker.watch-bars-command}.

    Structural-only: qualified [symbol] string, [timeframe] code
    string. Wire shape regenerated from the producer's .atd
    contract — byte-identical to the broker BC's inbound
    deserializer. *)

include module type of Watch_bars_command_t
include module type of Watch_bars_command_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t
