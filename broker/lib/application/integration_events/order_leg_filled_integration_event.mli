(** Integration event: one fill leg was observed at the venue
    against an order this broker adapter placed. One order may
    produce many of these events — every leg in a multi-fill
    sequence emits its own [Order_leg_filled] IE. Publishing
    terminates whether the order ended [Filled] or
    [Cancelled]/[Rejected] etc.; consumers detect order
    completion by comparing [new_total_filled] against the
    placement's intended quantity (or, in future, by listening
    for a dedicated [Order_filled] terminal event).

    Published on [in-memory://broker.order-leg-filled] by the
    live adapter when its WebSocket subscription delivers a
    trade update; consumed by [execution_management] for the
    saga's commit-fill leg.

    Identity: the saga key is [placement_id : int], which the
    adapter recovers from the venue-side [order_id] via its
    private placement map. [correlation_id] is recovered from
    the broker's command-log keyed on that [placement_id] so the
    outbound IE carries the originating Submit saga even though
    the WS event itself arrives outside command-in-scope.

    Paper-broker BC emits its own variant of this same wire
    contract ({!Paper_broker_integration_events.Order_leg_filled_integration_event})
    for paper-mode runs. Both live publishers and the
    paper-broker simulator target the same URI on the bus, so
    the EM consumer is source-agnostic. *)

include module type of Order_leg_filled_integration_event_t
include module type of Order_leg_filled_integration_event_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t

type domain = Broker_domain.Remote_broker.Events.Order_leg_filled.t

val of_domain : correlation_id:string -> domain -> t
(** Project the domain event onto the wire IE.

    [correlation_id] is the saga-instance id — the application
    layer retrieves it from the broker's command log via
    [origin_correlation_id ~placement_id] before invoking the
    projection. It is not part of the domain event because the
    adapter has no knowledge of the saga that originated the
    submit. *)
