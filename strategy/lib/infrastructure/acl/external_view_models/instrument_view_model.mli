(** Strategy-side inbound DTO mirror of an instrument view model.

    Structural-only: identifies the four wire fields. No
    [of_domain] / [type domain] — this DTO is consumed (deserialized
    or field-copied from an upstream BC's outbound DTO at the
    composition root), not produced from a strategy domain value.

    Wire shape regenerated from the producer's .atd contract. *)

include module type of Instrument_view_model_t
include module type of Instrument_view_model_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t
