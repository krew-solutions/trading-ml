(** Wire-shape projection of a single execution (trade / fill
    slice) for an order placement. Per-execution detail surfaces
    venue-actual price and fee — not the order's intended price.

    The parent order's identity is [placement_id], carried by the
    calling context (e.g., as the key passed to
    {!Broker.S.get_executions}). The wire shape is generated from
    [shared/contracts/broker/view_models/execution_view_model.atd]
    via atdgen. *)

include module type of Execution_view_model_t
include module type of Execution_view_model_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t

val of_domain : Order.trade -> t
(** Project broker's ACL-internal intermediate {!Order.trade}
    onto the wire view model. The placement_id parent identity is
    {b not} on the per-execution record — it is carried by the
    calling context which already addressed the placement. *)
