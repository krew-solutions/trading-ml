(** Inbound DTO mirror of an order view model. Used by the saga's
    [Order_accepted] inbound mirror.

    Wire shape regenerated from the producer's .atd contract. *)

include module type of Order_view_model_t
include module type of Order_view_model_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t
