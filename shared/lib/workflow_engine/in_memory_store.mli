(** In-memory implementation of {!Store.S}. Backed by a
    [Hashtbl] guarded by a non-reentrant {!Mutex}; suitable for
    single-process deployments where workflow state can be
    safely lost on restart. Matches the semantics of the
    in-memory bus shipped in this codebase.

    Persistent backends (Postgres, Redis, ...) implementing the
    same {!Store.S} signature can be substituted at engine
    construction time without touching workflow definitions. *)

include Store.S

val create : unit -> 'state t
