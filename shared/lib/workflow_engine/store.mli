(** Persistence port for workflow instance state.

    The engine treats the store as opaque; concrete backends
    (in-memory, Postgres, Redis, ...) own persistence and the
    atomicity of read-modify-write. The contract here is
    single-handle ACID: one engine process holding one store
    handle sees consistent semantics on its own operations.
    Cross-process coordination (multiple engines, distributed
    locks, idempotent re-delivery across processes) is **out
    of scope** for this signature — a distributed backend may
    add it on top, but the engine itself doesn't require it.

    Operations return discriminated outcomes rather than raise
    so the engine can decide whether a missing / duplicated
    instance is a contract violation (raise) or expected
    (idempotent drop). *)

module type S = sig
  type 'state t
  (** Store handle parameterised over the workflow's state type.
      One handle per workflow definition; multiple workflow
      definitions get separate handles even on the same backend. *)

  val put : 'state t -> correlation_id:string -> 'state -> [ `Ok | `Already_exists ]
  (** Insert a fresh entry. [`Already_exists] when
      [correlation_id] is already tracked — never silently
      overwrites, since that would mask collisions. *)

  val get : 'state t -> correlation_id:string -> 'state option
  (** Snapshot read; [None] for unknown / already-completed
      [correlation_id]. *)

  val update :
    'state t ->
    correlation_id:string ->
    f:('state -> [ `Replace of 'state | `Delete ]) ->
    [ `Updated | `Not_found ]
  (** Atomic read-modify-write. If [correlation_id] exists, [f]
      is invoked under the store's serialisation primitive with
      the current state and chooses to either [`Replace] it or
      [`Delete] the entry. [`Not_found] when the key is absent —
      [f] is not called.

      [f] must be a pure transition: any side effect inside it
      runs under the store's lock and may serialise concurrent
      updates for unrelated keys on backends with coarse
      locking. The engine deliberately uses [f] only for the
      pure {!Workflow_engine.WORKFLOW.transition} call and
      defers command dispatch until after [update] returns. *)

  val length : 'state t -> int
  (** Snapshot count of tracked entries. Approximate under
      concurrent backends — used only for diagnostics
      ({!Workflow_engine.Make.active_count}). *)
end
