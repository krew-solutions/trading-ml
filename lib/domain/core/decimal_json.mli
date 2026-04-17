(** JSON encoding for {!Decimal.t}, kept separate so [Decimal.mli]
    stays Gospel-checkable. *)

val yojson_of_t : Decimal.t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> Decimal.t

val yojson_of_t_wrapped : Decimal.t -> Yojson.Safe.t
(** gRPC [google.type.Decimal] wrapper: [{"value": "<string>"}]. *)

val of_yojson_flex : Yojson.Safe.t -> Decimal.t
(** Tolerant decoder: plain strings, numbers, and gRPC
    [{"value": "…", "scale": n}] wrappers. *)
