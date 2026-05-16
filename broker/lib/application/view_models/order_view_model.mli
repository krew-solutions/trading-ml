(** Wire-shape projection of an order's observable state.

    Identity in this projection is [placement_id]. Venue-native
    handles ([client_order_id], server-side ids, exec ids) are
    private to each ACL adapter and do not appear here.

    The wire shape is generated from
    [shared/contracts/broker/view_models/order_view_model.atd]
    via atdgen. *)

include module type of Order_view_model_t
include module type of Order_view_model_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t

val of_domain : Order.t -> t
(** Project the broker-domain order onto the wire view model.
    [placement_id] is already on [Order.t] (it is part of our
    identity), no longer passed separately. *)
