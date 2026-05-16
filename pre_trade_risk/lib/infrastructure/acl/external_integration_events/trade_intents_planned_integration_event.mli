(** pre_trade_risk-side mirror of PM's "trade intents planned"
    integration event. Wire shape regenerated from the producer's
    .atd contract — same source of truth as PM's outbound emitter. *)

include module type of Trade_intents_planned_integration_event_t
include module type of Trade_intents_planned_integration_event_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t
