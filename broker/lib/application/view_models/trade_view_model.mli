(** Wire-shape projection of a single trade (fill slice) for an
    order placement. Per-trade detail surfaces venue-actual
    price and fee — not the order's intended price.

    The parent order's identity is [placement_id], carried by the
    calling context (e.g., as the key passed to
    {!Broker.S.get_trades}). The wire shape is generated from
    [shared/contracts/broker/view_models/trade_view_model.atd]
    via atdgen. *)

include module type of Trade_view_model_t
include module type of Trade_view_model_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t

val of_domain : Order.Trade.t -> t
(** Project a domain {!Order.Trade.t} onto the wire view model.
    The [placement_id] parent identity is {b not} on the
    per-trade record — it is carried by the calling context
    which already addressed the placement. *)
