(** Trade — a single execution leg observed at the venue against
    an {!Order}. Child Entity of the [Order] aggregate.

    {b Entity, not Value Object.} Two trades with identical
    [quantity] / [price] / [fee] / [ts] but distinct [trade_id]
    are distinct executions and must never be conflated — venue
    dedup, reconciliation, audit, and settlement all key on the
    trade's identity. Value equality would wrongly merge them, so
    identity is load-bearing: [trade_id] is the identity. The
    Entity is immutable (a trade is a point-in-time fact and never
    transitions), which is orthogonal to its being an Entity —
    identity, not mutability, is the criterion.

    {b Subordinate to [Order].} A trade exists only as a fill
    against the order it belongs to; it is never loaded or changed
    independently of that order, so it is a child Entity rather
    than an aggregate root. The parent order carries
    [placement_id] / [instrument] / [side]; those are not repeated
    here — a trade scoped to its order inherits them. (The
    standalone {!Remote_broker.Events.Trade_executed} domain event
    does carry them, because it travels without a parent
    context.) *)

type t = {
  trade_id : string;
      (** Venue-side execution identifier (Finam Trade [trade_id] /
          BCS deal [tradeNum]). The Entity's identity. *)
  ts : int64;
      (** Venue-reported execution timestamp, normalised to int64
          epoch by the ACL adapter. *)
  quantity : Decimal.t;
      (** This trade's quantity. The sum over all of an order's
          trades equals the order's [filled]. *)
  price : Decimal.t;
      (** Venue-actual fill price for this trade (not the order's
          intended [Limit] price). *)
  fee : Decimal.t;  (** Venue-side commission for this trade. *)
}
