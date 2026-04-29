(** Event bus abstraction.

    {!S} is the signature any concrete bus must satisfy.
    Consumers needing transport-agnosticism take [(module S)] /
    use a functor over [S]; current implementation lives at the
    top level of this module as the default in-memory in-process
    bus over {!Eio.Stream} with on-the-wire string serialisation.

    Future Kafka / NATS / RabbitMQ implementations will be
    separate modules satisfying [S]; consumers written against
    [S] swap without rewrites. *)

module type S = sig
  type 'a t

  type subscription

  val publish : 'a t -> 'a -> unit
  (** Serialise (per the bus's codec) and enqueue. Returns
      immediately; subscribers run later in the bus's dispatch
      fiber. *)

  val subscribe : 'a t -> ('a -> unit) -> subscription
  (** Add a subscriber. Returned handle identifies it for
      {!unsubscribe}. *)

  val unsubscribe : 'a t -> subscription -> unit
  (** Remove the subscriber identified by [subscription]. No-op
      if the handle is unknown. *)
end

(** {1 Default in-memory implementation} *)

type 'a t

type subscription

val publish : 'a t -> 'a -> unit

val subscribe : 'a t -> ('a -> unit) -> subscription

val unsubscribe : 'a t -> subscription -> unit

val create :
  sw:Eio.Switch.t -> to_string:('a -> string) -> of_string:(string -> 'a) -> unit -> 'a t
(** Construct an in-memory bus parameterised over a typed payload
    [a]. The daemon dispatch fiber is spawned on [~sw]; closing
    the switch stops the fiber. Specific to this implementation —
    Kafka / NATS variants would have their own [create]. *)
