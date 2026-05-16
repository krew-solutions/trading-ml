(** Inbound DTO mirror of a trade-intent view model. Wire shape
    regenerated from PM's .atd contract; the consumer side sees the
    same structure as the producer with no drift possible. *)

include module type of Trade_intent_view_model_t
include module type of Trade_intent_view_model_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t
