(** An order as the external system (Finam broker firm)
    represents it.

    Produced by {!Dto.order_of_json} when the ACL parses a
    Finam payload (HTTP response today, WS push event
    tomorrow); {!Finam_broker} translates it to broker BC's
    domain [Order.t] by attaching the saga's [placement_id] and
    dropping the foreign-handle bookkeeping.

    Distinct from {!Broker_domain.Order.t} which is broker BC's
    {b internal} abstraction (placement_id identity, our
    invariants). This {b external} sibling carries Finam's
    bookkeeping handles ([client_order_id], [order_id],
    [exec_id]) needed to route subsequent calls back to Finam;
    the handles live entirely inside the finam library and
    never cross the ACL boundary. *)

type t = {
  client_order_id : string;
      (** UUIDv4 (dashes stripped — Finam's "letters / numbers /
          space only" format) we supplied on placement. *)
  order_id : string;
      (** Finam's server-assigned identifier (Finam protocol
          field [order_id]). Distinct from [client_order_id] —
          Finam mints its own id and uses it as the address key
          on subsequent operations. *)
  exec_id : string;
      (** Finam's [exec_id], the bookkeeping id propagated
          on trade records so executions can be linked back to
          the parent order. *)
  instrument : Core.Instrument.t;
  side : Core.Side.t;
  quantity : Decimal.t;
  filled : Decimal.t;
  kind : Order.kind;
  tif : Order.time_in_force;
  status : Order.status;
  placed_ts : int64;
      (** Finam's [transact_at] parsed into int64 epoch — the
          domain-event timestamp of the placement, as the
          external system reports it. *)
}

val to_broker_domain : placement_id:int -> t -> Order.t
(** Project to broker BC's internal domain order by attaching
    the saga's [placement_id]. Finam-side handles
    ([client_order_id], [order_id], [exec_id]) are dropped —
    they never leave the finam library. *)
