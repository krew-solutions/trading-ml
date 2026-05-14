(** Domain Event: a working order was filled (fully or partially)
    against an incoming candle. Carries the actuals of the fill
    plus the cumulative filled total so consumers can apply the
    transactional effect atomically.

    [reservation_id] is the client's identifier of the order, echoed
    so consumers (e.g. Account) can locate the matching ledger
    state on commit.

    Whether the fill closes the order is derivable from
    [new_total_filled] versus the original [quantity] announced by
    {!Order_accepted}. Keeping the order's lifecycle status off this
    event avoids a peer-subdir cycle between [events/] and [values/]
    inside the [order] aggregate (and aligns with the project's
    other domain events, which carry only outcome data, never the
    aggregate's status field). *)

type t = {
  id : string;
  reservation_id : Values.Reservation_id.t;
  exec_id : string;
  instrument : Core.Instrument.t;
  side : Core.Side.t;
  fill_quantity : Decimal.t;
      (** Quantity filled by this single observation, always positive. *)
  fill_price : Decimal.t;  (** Actual fill price (post-slippage). *)
  fee : Decimal.t;  (** Actual fee charged. *)
  new_total_filled : Decimal.t;
      (** Cumulative filled quantity on the order after this event. *)
  fill_ts : int64;
}
