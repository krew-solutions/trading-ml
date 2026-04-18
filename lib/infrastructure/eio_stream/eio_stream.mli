(** Boundary adapter: an {!Eio.Stream.t} (effectful, push-based,
    concurrency-aware) presented as a pure {!Stream.t} (lazy,
    pull-based) so downstream pipelines in [lib/domain/] can consume
    live events with the same combinators they use for historical
    replays.

    This module is the only place Eio's push-model meets our
    functional pull-model. Everything above it is pure [Seq.t]
    transformations; everything below is regular Eio concurrency
    (fibers, mutexes, switches). That split is deliberate — it keeps
    the domain layer Eio-free and lets pipelines be tested with
    {!Stream.of_list} inputs, then run in production against an Eio
    source with no code change. *)

val of_eio_stream : 'a Eio.Stream.t -> 'a Stream.t
(** Wrap [s] as an infinite {!Stream.t}. Each forced [Cons]
    blocks the current fiber on {!Eio.Stream.take} until a value
    becomes available.

    The returned stream is **effectively infinite** — it never
    yields [Nil] on its own. Callers must bound the work with
    {!Stream.take}, {!Stream.iter} on a cancellable fiber, or
    equivalent.

    Single-consumer semantics: if two fibers pull from the same
    {!Stream.t}, each forced node independently consumes one
    value from the underlying [Eio.Stream], and the two fibers
    see disjoint subsets of the source — usually not what you
    want. Pull from one fiber, fan out via Stream combinators. *)
