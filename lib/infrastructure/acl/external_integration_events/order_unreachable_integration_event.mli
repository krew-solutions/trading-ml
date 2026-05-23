(** Server-side inbound DTO mirror of {b broker.order-unreachable}.

    Structural-only: [correlation_id], [placement_id], [reason].
    Consumed at the SSE inbound seam and re-emitted on the
    [order] SSE channel.

    Wire shape regenerated from the producer's .atd contract. *)

include module type of Order_unreachable_integration_event_t
include module type of Order_unreachable_integration_event_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t
