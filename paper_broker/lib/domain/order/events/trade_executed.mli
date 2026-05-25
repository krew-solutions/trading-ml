(** Domain Event: a trade was executed against a working order
    by an incoming candle (a full or partial fill). Carries the
    actuals of the trade only — [quantity], [price], [fee], [ts].

    [placement_id] is the client's identifier of the order, echoed
    so consumers (e.g. Account, via the saga) can locate the
    matching ledger state on commit.

    The event does not carry a cumulative filled total: the paper
    venue, like a real one, reports trades, and reconciling them
    into a running total is the consuming aggregate's job (the
    OrderTicket in execution_management). The order's own [filled]
    field still tracks the cumulative internally to decide whether
    a fill closes the order — that status is kept off this event
    to avoid a peer-subdir cycle between [events/] and [values/]
    inside the [order] aggregate. *)

type t = {
  id : string;
  placement_id : Values.Placement_id.t;
  trade_id : string;
  instrument : Core.Instrument.t;
  side : Core.Side.t;
  quantity : Decimal.t;
      (** Quantity filled by this single observation, always positive. *)
  price : Decimal.t;  (** Actual fill price (post-slippage). *)
  fee : Decimal.t;  (** Actual fee charged. *)
  ts : int64;
}
