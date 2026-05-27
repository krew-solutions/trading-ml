(** Inbound command to the order_flow BC: ingest one public-tape print.

    Wire-format DTO — primitives only, no domain values. [price]/[size]
    are Decimal strings (ADR 0007), [ts] is ISO-8601, [aggressor] is a
    token (BUY | SELL | UNSPECIFIED). The handler parses these into the
    [Print] value object. *)

include module type of Ingest_print_command_t
include module type of Ingest_print_command_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t
