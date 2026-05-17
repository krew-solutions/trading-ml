(** Process-local {!Ticket_store.S} implementation backed by a
    [Hashtbl] keyed by [Ticket_id.t].

    Transitional storage — mirrors {!Workflow_engine.In_memory_store}
    in semantics: state survives only the current process, no
    durability. Durable backend (Postgres / EventStore) lands in
    a follow-up (see ADR 0018 TODO).

    Thread-safety: operations acquire an internal mutex so
    concurrent fibers driving different tickets don't race on
    the underlying table. Per-ticket serialisation is the
    caller's concern (the engine running the workflow holds its
    own per-key lock, but the store does not coordinate
    multi-fiber writes on the same key). *)

include Execution_management_ports.Ticket_store.S

val create : unit -> t
