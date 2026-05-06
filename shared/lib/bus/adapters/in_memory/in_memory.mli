(** In-memory adapter for {!Bus}. URIs of the form ["in-memory://X"]
    route to a per-{!broker} registry of topics. The adapter is the
    monolithic-deployment counterpart of a future Kafka/Redpanda
    adapter — same API surface, same group semantics, no network. *)

type broker
(** Process-local broker. Holds a registry of topics, a dispatch
    fiber, and a mutex. Each {!create} returns an isolated instance —
    distinct brokers do not share topics or subscribers. *)

val create : sw:Eio.Switch.t -> broker
(** Construct a fresh broker. The dispatch fiber runs on [sw]; all
    consumers tear down when [sw] is released. *)

val adapter : broker -> (module Bus.Adapter)
(** Adapter facade over [broker]. Pass to {!Bus.register} to bind a
    URI scheme (typically ["in-memory"]) to this broker. *)

exception Already_registered_in_group of { uri : string; group : string }
(** Raised when a second consumer tries to join the same
    [(uri, group)] on this broker. Single-consumer-per-group is a
    deliberate invariant: in monolithic deployments each logical role
    is one instance, and a second consumer in the same group is
    always a configuration bug. *)
