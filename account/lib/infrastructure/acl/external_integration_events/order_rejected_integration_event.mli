(** Account-side mirror of the Broker BC's "order rejected by
    upstream" integration event.

    Wire shape regenerated from the producer's .atd contract.
    [placement_id] is the cross-BC saga key (echoed back by Broker
    from the originating Submit command); Account's handler maps it
    to a local {!Release_command.reservation_id} when releasing the
    matching reservation. *)

include module type of Order_rejected_integration_event_t
include module type of Order_rejected_integration_event_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t
