(** Mirror of {!Account_integration_events.Amount_reserved_integration_event.t}.
    Wire shape regenerated from the producer's .atd contract. *)

include module type of Amount_reserved_integration_event_t
include module type of Amount_reserved_integration_event_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t
