(** Account-side inbound DTO mirror of an instrument view model.

    Structural-only: identifies the four wire fields. No
    [of_domain] / [type domain] — this DTO is consumed (deserialized
    from an upstream BC's outbound JSON), not produced from an
    Account domain value. Kept independent of
    {!Account_view_models.Instrument_view_model} (Account's own
    outbound projection) so that the inbound and outbound sides of
    the wire can evolve their schemas independently.

    Wire shape regenerated from the producer's .atd contract. *)

include module type of Instrument_view_model_t
include module type of Instrument_view_model_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t
