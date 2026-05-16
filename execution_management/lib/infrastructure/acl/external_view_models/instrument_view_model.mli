(** Inbound DTO mirror of an instrument view model. Structural-only;
    wire shape regenerated from the producer's .atd contract. *)

include module type of Instrument_view_model_t
include module type of Instrument_view_model_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t
