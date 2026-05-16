(** Account-side mirror of the Broker BC's "order accepted"
    integration event.

    Wire shape regenerated from the producer's .atd contract;
    structural drift between Broker's outbound emitter and this
    Account-side mirror is a compile-time error. *)

include module type of Order_accepted_integration_event_t
include module type of Order_accepted_integration_event_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t
