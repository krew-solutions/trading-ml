(** Persistence port for {!Pending_order.t} — application-layer
    records that wrap a {!Paper_broker.Order.t} aggregate with the
    cross-BC opaque correlation token.

    Mirrors the {!Shared.Workflow_engine.Store.S} shape: atomic
    [update] under the store's serialisation primitive and
    discriminated outcomes instead of raising.

    Two extras over the workflow-engine port are intrinsic to a
    matching simulator that processes bars:
    - {!find_active} — every bar tick scans the set of orders that
      are not yet terminal; expressed at the port so backends can
      index it (e.g. a Postgres adapter maintaining a partial
      index on [status NOT IN ('Filled','Cancelled','Rejected','Expired')]).
    - The whole-sweep coarse lock is the adapter's concern: callers
      iterate {!find_active} and {!update} per id; the in-memory
      adapter serialises them under a single mutex. *)

module type S = sig
  type t

  val save : t -> Pending_order.t -> [ `Ok | `Already_exists ]
  (** Insert a freshly accepted pending order keyed by
      {!Pending_order.id}. [`Already_exists] when the id is already
      tracked — never silently overwrites, since that would mask
      collisions. *)

  val find : t -> id:string -> Pending_order.t option
  (** Snapshot read by primary id. [None] for unknown id. *)

  val find_active : t -> Pending_order.t list
  (** Snapshot of every pending order whose status is not terminal.
      Used by the per-bar matching sweep. Ordering is unspecified —
      consumers must not depend on insertion order. *)

  val update :
    t ->
    id:string ->
    f:(Pending_order.t -> [ `Replace of Pending_order.t | `Delete ]) ->
    [ `Updated | `Not_found ]
  (** Atomic read-modify-write for a single pending order. [f] is
      invoked under the store's serialisation primitive with the
      current state and chooses to either [`Replace] it or
      [`Delete] the entry. [`Not_found] when [id] is absent — [f]
      is not called.

      [f] must be a pure transition: any side effect inside it
      runs under the store's lock. *)

  val length : t -> int
  (** Approximate snapshot count of tracked pending orders —
      diagnostics only. *)
end
