(** Repository port for {!Paper_broker.Order.t} aggregates.

    Pure {!Paper_broker.Order.t} in / {!Paper_broker.Order.t} out —
    process correlation metadata (the [correlation_id] of the saga
    that submitted, cancelled, etc.) lives in a separate
    {!Order_command_log.S}, not bundled with the aggregate. See
    *Process correlation is not aggregate state* in
    [docs/architecture/hexagonal-architecture.md] for the
    rationale.

    Mirrors the {!Shared.Workflow_engine.Store.S} shape: atomic
    [update] under the store's serialisation primitive and
    discriminated outcomes instead of raising. Two extras over the
    workflow-engine port are intrinsic to a matching simulator:
    - {!find_active} for the per-bar sweep.
    - The whole-sweep coarse lock is the adapter's concern. *)

module type S = sig
  type t

  val save : t -> Paper_broker.Order.t -> [ `Ok | `Already_exists ]
  (** Insert a freshly accepted order, keyed by {!Paper_broker.Order.t.id}. *)

  val find : t -> id:string -> Paper_broker.Order.t option
  (** Snapshot read by id. *)

  val find_active : t -> Paper_broker.Order.t list
  (** Snapshot of every order whose status is not terminal. Used
      by the per-bar matching sweep. Ordering is unspecified. *)

  val update :
    t ->
    id:string ->
    f:(Paper_broker.Order.t -> [ `Replace of Paper_broker.Order.t | `Delete ]) ->
    [ `Updated | `Not_found ]
  (** Atomic read-modify-write under the store's serialisation
      primitive. *)

  val update_by_placement_id :
    t ->
    placement_id:int ->
    f:(Paper_broker.Order.t -> [ `Replace of Paper_broker.Order.t | `Delete ]) ->
    [ `Updated | `Not_found ]
  (** Same as {!update} but addressing an order by its cross-BC
      [placement_id] (the saga key) rather than the paper_broker-
      assigned surrogate [Order.id]. Required by
      {!Cancel_pending_order_command_handler}: the saga does not
      know paper_broker's local id; it only knows the placement
      it submitted under.

      Atomicity is the same as {!update} — the lookup and the
      [f] application happen under one serialisation cycle. *)

  val length : t -> int
  (** Approximate snapshot count — diagnostics only. *)
end
