(** In-memory event bus: pub/sub with on-the-wire serialisation.

    {b Asynchronous.} [publish] serialises the event to a [string]
    and enqueues it on a bounded [Eio.Stream.t]; control returns to
    the caller immediately. A daemon fiber owned by the bus drains
    the queue, deserialises each payload, and dispatches to every
    subscriber in registration order. Subscribers run inside the
    dispatch fiber sequentially per event; a raising subscriber is
    isolated (logged) and the next subscriber still fires.

    {b Strings on the wire.} The bus models a real network bus
    (RabbitMQ / NATS / Kafka): values cross the boundary as opaque
    [string]s, and the producer / consumer contract is the codec
    pair supplied at {!create}. Events that don't round-trip
    through their [to_string] / [of_string] simply can't ride this
    bus — caught at publish time, no [Marshal]-style runtime traps.

    {b Subscriptions} are reified as opaque values returned from
    {!subscribe} so callers can {!unsubscribe} when their lifetime
    ends. Subscriptions can be added / removed concurrently with
    publish — internal mutex serialises mutation. *)

type 'a t

type subscription

val create :
  sw:Eio.Switch.t -> to_string:('a -> string) -> of_string:(string -> 'a) -> unit -> 'a t
(** Construct a bus parameterised over a typed payload [a]. The
    daemon dispatch fiber is spawned on [~sw]; closing the switch
    stops the fiber. *)

val subscribe : 'a t -> ('a -> unit) -> subscription
(** Add a subscriber. Returned handle identifies it for {!unsubscribe}. *)

val unsubscribe : 'a t -> subscription -> unit
(** Remove the subscriber identified by [subscription]. No-op if
    the handle is unknown to this bus. *)

val publish : 'a t -> 'a -> unit
(** Serialise [event] and enqueue. Non-blocking under normal
    queue depth; blocks the caller fiber if the underlying stream
    is at capacity (1024). *)
