(** In-memory adapter for the
    {!Paper_broker_commands.Order_store.S} port.

    Single coarse {!Stdlib.Mutex.t} around a {!Stdlib.Hashtbl.t}.
    Coarse is deliberate, not lazy: a paper-broker simulator's
    workload is single-bar sweeps and per-order submits/cancels —
    contention is low, and a coarse lock makes
    [save → find_active → update] sequences trivially serialisable
    without a finer-grained scheme. {!Stdlib.Mutex} (rather than
    Eio's cancellation-aware mutex) is sufficient because every
    critical section is non-blocking and effect-free; the lock is
    held only across [Hashtbl] operations and pure [f] transitions.

    No durability: restart wipes the store. Future deployments that
    need persistence implement the port against Postgres / SQLite
    without changing any caller. *)

include Paper_broker_commands.Order_store.S

val create : unit -> t
