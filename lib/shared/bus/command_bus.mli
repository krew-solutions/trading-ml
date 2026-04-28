(** Command bus abstraction.

    {!S} is the signature any concrete bus must satisfy.
    Consumers needing transport-agnosticism take [(module S)] /
    use a functor over [S]; current implementation lives at the
    top level of this module as the default in-memory in-process
    bus.

    Future networked command-bus implementations (e.g. NATS
    request pattern) will be separate modules satisfying [S];
    consumers written against [S] swap without rewrites. *)

module type S = sig
  type 'a t

  exception Already_registered

  exception No_handler

  val register_handler : 'a t -> ('a -> unit) -> unit
  (** Bind THE handler. Raises {!Already_registered} on the
      second call. *)

  val send : 'a t -> 'a -> unit
  (** Serialise and enqueue. Fire-and-forget by CQRS contract:
      outcomes flow through {!Event_bus} integration events, not
      back through this bus. *)
end

(** {1 Default in-memory implementation} *)

type 'a t

exception Already_registered

exception No_handler

val register_handler : 'a t -> ('a -> unit) -> unit

val send : 'a t -> 'a -> unit

val create :
  sw:Eio.Switch.t -> to_string:('a -> string) -> of_string:(string -> 'a) -> unit -> 'a t
