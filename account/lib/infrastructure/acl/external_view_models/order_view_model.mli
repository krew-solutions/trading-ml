(** Account-side inbound DTO mirror of an order view model.

    Structural-only: identifies the wire fields the upstream Broker
    BC publishes alongside its [order_accepted] integration event.
    [quantity] / [filled] / [remaining] are decimal strings
    (bit-exact roundtrip with the upstream [Decimal.to_string]
    form); [created_ts] is an [int64] epoch counter.

    Wire shape regenerated from the producer's .atd contract. *)

include module type of Order_view_model_t
include module type of Order_view_model_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t
