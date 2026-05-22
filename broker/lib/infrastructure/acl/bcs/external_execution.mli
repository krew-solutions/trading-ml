(** An execution leg ("deal" / "trade") as the external system
    (BCS broker firm) represents it.

    Produced by {!Rest.bcs_trade_of_json} when the ACL parses a
    record from [POST /trade-api-bff-trade-details/api/v1/trades/search]
    (and from the [/orders/execution/ws] WebSocket channel via
    {!Order_event.to_domain}, which lifts the WS payload through
    the same wire shape). The bcs library translates it to the
    broker BC's domain [Order_leg_filled.t] in {!Bcs_broker} once
    the parent [placement_id] is resolved.

    Distinct from {!Broker_domain.Order.trade} which is the broker
    BC's per-leg view stripped of foreign-handle bookkeeping; this
    {b external} sibling carries the [order_num] needed to
    correlate back to the parent order and the venue-side
    [trade_id] used for cross-transport dedup. The handles live
    entirely inside the bcs library and never cross the ACL
    boundary. *)

type t = {
  order_num : string;
      (** Venue-side parent order id (BCS [orderNum]). Used by
          the adapter to find the originating [placement_id]
          via {!Placement_handle_store}. *)
  trade_id : string;
      (** Venue-side per-leg execution id (BCS [tradeNum]).
          Stable across WS and REST transports — both branches
          parse it from the same wire field — which makes it
          the natural cross-transport dedup discriminator. *)
  instrument : Core.Instrument.t;
  side : Core.Side.t;
  ts : int64;
  quantity : Decimal.t;
  price : Decimal.t;
  fee : Decimal.t;
      (** Per-leg commission. BCS does not surface this on the
          deals payload today, so the parser defaults to zero
          and the field is reserved for the day BCS adds it. *)
}
