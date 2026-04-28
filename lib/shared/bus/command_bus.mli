(** In-memory command bus: address-style 1-to-1 dispatch with
    on-the-wire serialisation.

    {b Asynchronous fire-and-forget.} [send] serialises the
    command to a [string], enqueues it, and returns. The single
    handler runs in the bus's daemon dispatch fiber. Outcomes are
    {b not} carried back through this bus — they surface on the
    appropriate {!Event_bus} the handler publishes to. This is the
    CQRS contract (commands change state, don't return data) and
    matches the physics of any real network bus where [send] is
    inherently fire-and-forget.

    {b Strings on the wire.} Same as {!Event_bus} — the codec pair
    supplied at {!create} is the on-the-wire contract; a command
    type that doesn't round-trip through it simply can't travel.

    {b Single handler invariant.} {!register_handler} accepts
    exactly one binding; the second call raises {!Already_registered}.
    Composition root invariant: each command type has exactly one
    owner BC. *)

type 'a t

val create :
  sw:Eio.Switch.t -> to_string:('a -> string) -> of_string:(string -> 'a) -> unit -> 'a t

exception Already_registered

val register_handler : 'a t -> ('a -> unit) -> unit
(** Bind THE handler. Raises {!Already_registered} on the second
    call. *)

exception No_handler

val send : 'a t -> 'a -> unit
(** Serialise and enqueue. Non-blocking under normal queue depth;
    blocks the caller fiber if the underlying stream is at
    capacity (1024). *)
