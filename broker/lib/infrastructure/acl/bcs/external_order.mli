(** An order as the external system (BCS broker firm)
    represents it.

    Produced by {!Rest.bcs_order_of_json} when the ACL parses a
    BCS payload (HTTP response today, WS push event tomorrow);
    {!Bcs_broker} translates it to broker BC's domain [Order.t]
    by attaching the saga's [placement_id] and dropping the
    foreign-handle bookkeeping.

    Distinct from {!Broker_domain.Order.t} which is broker BC's
    {b internal} abstraction (placement_id identity, our
    invariants). This {b external} sibling carries BCS's
    bookkeeping handles ([client_order_id], [exec_id]) needed to
    route subsequent calls back to BCS; the handles live entirely
    inside the bcs library and never cross the ACL boundary. *)

type t = {
  client_order_id : string;
      (** UUIDv4 we minted and supplied to BCS — BCS treats it
          as the server-side id too. *)
  exec_id : string;
      (** BCS [orderNum], the bookkeeping id BCS issues so deals
          can link back to the parent order. Empty until the
          order has been accepted by the matching engine. *)
  instrument : Core.Instrument.t;
  side : Core.Side.t;
  quantity : Decimal.t;
  filled : Decimal.t;
  kind : Order.kind;
  tif : Order.time_in_force;
  status : Order.status;
  placed_ts : int64;
      (** Venue's [createdAt] parsed into int64 epoch — the
          domain-event timestamp of the placement. *)
}

val to_broker_domain : placement_id:int -> t -> Order.t
(** Project to broker BC's internal domain order by attaching
    the saga's [placement_id]. BCS-side handles
    ([client_order_id], [exec_id]) are dropped — they never
    leave the bcs library. *)
