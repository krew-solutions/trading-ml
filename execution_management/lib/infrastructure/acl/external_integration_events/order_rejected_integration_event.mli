(** Mirror of {!Broker_integration_events.Order_rejected_integration_event.t}.
    Wire shape regenerated from the producer's .atd contract. *)

include module type of Order_rejected_integration_event_t
include module type of Order_rejected_integration_event_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t
