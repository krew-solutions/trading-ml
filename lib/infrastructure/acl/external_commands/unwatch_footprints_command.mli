(** Server-side outbound DTO mirror of {b order-flow.unwatch-footprints-command}.

    Structural-only: qualified [symbol] string, [boundary] token string
    ("M5", "VOL:1000"). Wire shape regenerated from the producer's .atd
    contract — byte-identical to the order_flow BC's inbound deserializer. *)

include module type of Unwatch_footprints_command_t
include module type of Unwatch_footprints_command_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t
