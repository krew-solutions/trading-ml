(** Wire mirror of broker's [Bar_updated_integration_event]. EM
    subscribes per ADR 0023 to drive the volume-feed and market-
    data adapters; the handler translates each bar into typed
    domain VOs and pushes them into the in-process adapter
    instances. *)

include module type of Bar_updated_integration_event_t

include module type of Bar_updated_integration_event_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t
