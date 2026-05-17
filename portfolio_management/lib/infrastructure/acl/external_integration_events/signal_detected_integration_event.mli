(** PM-side mirror of {!Strategy_integration_events.Signal_detected_integration_event.t}.

    Wire shape regenerated from the producer's .atd contract.
    Per the [Order_process_manager] correlation chain the event itself
    is not part of a saga (alpha-mind lives above the
    order-placement saga, no correlation_id needed). *)

include module type of Signal_detected_integration_event_t
include module type of Signal_detected_integration_event_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t
