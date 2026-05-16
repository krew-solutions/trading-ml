(** Account-side inbound DTO mirror of an order-kind view model.

    Structural-only: tagged-union projection of [Market | Limit |
    Stop | Stop_limit] flattened to four fields. No [of_domain] /
    [type domain] — this DTO is consumed (deserialized from an
    upstream BC's outbound JSON), not produced from an Account
    domain value.

    Wire shape regenerated from the producer's .atd contract. *)

include module type of Order_kind_view_model_t
include module type of Order_kind_view_model_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t
