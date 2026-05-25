(** Domain event — the remote broker reports one executed trade
    leg for one of our placements. Recognised by the ACL adapter
    from the broker's wire frame (Finam WS trade update, BCS deal
    payload) and emitted into [Remote_broker.Events].

    The event carries the trade itself only — this leg's
    [quantity], [price], [fee], and [ts]. The broker does not
    aggregate cumulative fill state; reconciling legs into a
    placement's running total is the consuming aggregate's
    responsibility (the OrderTicket in execution_management),
    keeping the broker a pure recognizer of external facts (per
    Vernon, "external system as a source of Domain Events").

    Execution-leg fields are flattened rather than nested under an
    [Execution.t] Value Object because the wrapped-library layout
    (qualified subdirs with collapse-rule main module) forbids a
    child event module from referencing a type defined in its
    parent module. Promoting the execution leg to a proper Value
    Object is a follow-up tidy. *)

type t = {
  placement_id : int;
      (** Cross-BC saga key minted by Account at reservation
          time, echoed through Submit, and recognised here on
          the inbound side. Subscribers correlate broker trades
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
  quantity : Decimal.t;  (** This trade's quantity. *)
  price : Decimal.t;
      (** Broker-reported price of this trade (the price at which
          the venue actually filled, not the intended [Limit]
          price). *)
  fee : Decimal.t;
  ts : int64;
      (** Broker-reported execution timestamp, normalised to
          int64 epoch by the ACL adapter. *)
}
