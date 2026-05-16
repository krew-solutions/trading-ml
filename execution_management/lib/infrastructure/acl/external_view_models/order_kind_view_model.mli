(** Inbound DTO mirror of broker's [Order_kind_view_model]. Used by
    {!Place_order_pm}'s state — the saga needs the kind to forward
    into the {!Submit_order_command} once the reservation lands.

    Wire shape regenerated from the producer's .atd contract. *)

include module type of Order_kind_view_model_t
include module type of Order_kind_view_model_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t
