(** Per-key running sum. Tracks a cumulative [value] for each
    [key]; each [bump] adds a delta and returns the new total.

    Use case: per-placement cumulative-fill accumulation in
    broker adapters — each [Order_leg_filled] event carries a
    single leg's quantity, and the cumulative quantity observed
    across all legs for the same [placement_id] is the
    aggregate-state snapshot the adapter ships on the domain
    event. The adapter is the recognizer of these external
    facts (per Vernon); the cumulative is bookkeeping derived
    from the sequence of observed legs and naturally lives here
    in the ACL layer.

    Concurrency: not thread-safe by itself. Callers that share
    one instance across fibers must serialise [bump] under
    their own mutex (e.g. [Eio.Mutex.use_rw]). Single-fiber
    callers can use it directly. *)

type ('key, 'value) t

val create : zero:'value -> add:('value -> 'value -> 'value) -> ('key, 'value) t

val bump : ('key, 'value) t -> key:'key -> delta:'value -> 'value
(** Add [delta] to the cumulative recorded for [key] (starting from
    [zero] if [key] is new) and return the new total. *)
