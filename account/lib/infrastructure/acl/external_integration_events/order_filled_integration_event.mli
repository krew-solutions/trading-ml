(** Account-side mirror of the paper_broker BC's "order filled"
    integration event published on [in-memory://broker.order-filled].

    Wire shape regenerated from the producer's .atd contract.
    [placement_id] is the cross-BC saga key; Account's handler maps
    it to a local {!Commit_fill_command.reservation_id}. The handler
    likewise reads [fill_quantity] / [fill_price] from the producer
    contract and projects them onto the Account command's
    [quantity] / [price] decimal-string fields. *)

include module type of Order_filled_integration_event_t
include module type of Order_filled_integration_event_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t
