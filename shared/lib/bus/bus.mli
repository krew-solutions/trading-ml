(** Scheme-dispatched message bus.

    The bus is a runtime registry of {!Adapter} implementations keyed
    by URI scheme. A callsite writing
    [Bus.consumer bus ~uri:"in-memory://X" ~group ~deserialize] does not
    name the concrete transport — the [in-memory] prefix dispatches to
    the adapter registered for that scheme. Replacing transport is a
    one-line change to [Bus.register] in the composition root; nothing
    else moves.

    The bus carries opaque wire payloads. Producers serialize values to
    [string] when {!publish}-ing; consumers deserialize incoming
    [string]s on receipt. Two consumers on the same URI may use
    different deserializers — the wire JSON is the contract; OCaml types
    are local to each side. This is what makes a cross-BC connection
    work without a translation function: each side simply describes how
    it reads the wire. *)

type subscription
(** Opaque handle returned by {!subscribe}. Pass to {!unsubscribe} to
    detach. *)

type 'a consumer
(** Typed consumer handle for a particular [(uri, group)] pair.
    Constructed by {!consumer}. *)

type 'a producer
(** Typed producer handle for a particular [uri].
    Constructed by {!producer}. *)

type bus
(** Dispatcher state — registry of [scheme → adapter]. Constructed by
    {!create}. Per-bus state means tests can run in parallel with their
    own bus instances; there is no global state. *)

(** {1 Adapter contract}

    Each transport implementation provides this signature. Bus uses it
    to construct typed adapter handles and forwards calls through them. *)
module type Adapter = sig
  type 'a adapter_consumer
  type 'a adapter_producer
  type adapter_subscription

  val consumer :
    uri:string -> group:string -> deserialize:(string -> 'a) -> 'a adapter_consumer

  val producer : uri:string -> serialize:('a -> string) -> 'a adapter_producer

  val publish : 'a adapter_producer -> 'a -> unit

  val subscribe : 'a adapter_consumer -> ('a -> unit) -> adapter_subscription

  val unsubscribe : adapter_subscription -> unit
end

exception Already_registered of string
(** Raised by {!register} when the scheme is already bound to another
    adapter. *)

exception Unknown_scheme of string
(** Raised by {!consumer} / {!producer} when the URI's scheme has no
    registered adapter, or the URI has no scheme prefix at all. *)

(** {1 Lifecycle} *)

val create : unit -> bus
(** Fresh dispatcher with no registered adapters. *)

val register : bus -> scheme:string -> (module Adapter) -> unit
(** Bind [scheme] to [adapter] inside [bus]. After this call, every
    URI of the form ["scheme://..."] resolves to this adapter when
    passed to {!consumer} / {!producer}. *)

(** {1 Operations} *)

val consumer :
  bus -> uri:string -> group:string -> deserialize:(string -> 'a) -> 'a consumer

val producer : bus -> uri:string -> serialize:('a -> string) -> 'a producer

val publish : 'a producer -> 'a -> unit

val subscribe : 'a consumer -> ('a -> unit) -> subscription

val unsubscribe : subscription -> unit
