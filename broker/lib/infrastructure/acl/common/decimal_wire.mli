(** JSON encoding/decoding helpers for {!Decimal.t} at the
    broker wire boundary. Lives in ACL, not in [core], because
    decimal JSON encoding is entirely a wire-format concern — the
    domain type itself knows nothing about JSON. *)

val yojson_of_t : Decimal.t -> Yojson.Safe.t
(** Canonical string encoding used by most broker APIs. *)

val t_of_yojson : Yojson.Safe.t -> Decimal.t

val yojson_of_t_wrapped : Decimal.t -> Yojson.Safe.t
(** gRPC [google.type.Decimal] wrapper: [{"value": "<string>"}].
    Required by Finam's REST API for price/quantity fields in
    order placement. *)

val of_yojson_flex : Yojson.Safe.t -> Decimal.t
(** Tolerant decoder: plain strings, numbers, and gRPC
    [{"value": "…", "scale": n}] wrappers — used by any broker
    DTO that ingests decimal fields from the wire. *)
