(** Domain event — the remote broker reports one execution leg
    for one of our placements. Recognised by the ACL adapter
    from the broker's wire frame (Finam WS trade update, BCS
    deal payload) and emitted into [Remote_broker.Events].

    [new_total_filled] is the cumulative quantity observed across
    all legs the adapter has so far reported for this
    [placement_id] — the adapter is the bookkeeper of this
    cumulative (per Vernon, the recognizer of external facts may
    accrue local state derived from the sequence of observed
    facts). Downstream consumers may rely on this snapshot or
    re-derive it themselves from the event stream.

    Execution-leg fields ([fill_quantity], [fill_price], [fee],
    [fill_ts]) are flattened rather than nested under an
    [Execution.t] Value Object because the wrapped-library layout
    (qualified subdirs with collapse-rule main module) forbids a
    child event module from referencing a type defined in its
    parent module. Promoting the execution leg to a proper Value
    Object is a follow-up tidy. *)

type t = {
  placement_id : int;
      (** Cross-BC saga key minted by Account at reservation
          time, echoed through Submit, and recognised here on
          the inbound side. Subscribers correlate broker fills
          back to the originating Submit through this id
          (combined with the [correlation_id] the
          application-layer event handler retrieves from the
          broker's command log when projecting to the
          integration event). *)
  trade_id : string;
      (** Venue-side fill identifier echoed by the broker
          (Finam Trade.update [trade_id] / BCS deal [tradeNum]).
          Carried on the domain event so consumers — including
          the wire integration event — can use it as a candidate
          idempotency token for Transactional Inbox dedup.
          Cardinality versus [placement_id] is venue-specific
          and not assumed at this layer. *)
  instrument : Core.Instrument.t;
  side : Core.Side.t;
  fill_quantity : Decimal.t;  (** This leg's quantity. *)
  fill_price : Decimal.t;
      (** Broker-reported price of this leg (the price at which
          the venue actually filled, not the intended [Limit]
          price). *)
  fee : Decimal.t;
  fill_ts : int64;
      (** Broker-reported execution timestamp, normalised to
          int64 epoch by the ACL adapter. *)
  new_total_filled : Decimal.t;
      (** Cumulative quantity observed for this [placement_id]
          across all legs the adapter has so far reported,
          including this one. *)
}
