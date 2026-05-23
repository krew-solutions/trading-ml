(** Server-side inbound DTO mirror of {b broker.bar-updated}.

    Structural-only: instrument + timeframe + candle as wire
    strings. Consumed (deserialized at the SSE inbound seam),
    never produced — there is no [of_domain] direction here.

    Wire shape regenerated from the producer's .atd contract,
    same source of truth as the broker BC's outbound emitter. *)

include module type of Bar_updated_integration_event_t
include module type of Bar_updated_integration_event_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t
