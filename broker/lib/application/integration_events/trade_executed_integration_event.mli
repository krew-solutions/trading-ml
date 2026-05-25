(** Integration event: one trade leg was executed at the venue
    against an order this broker adapter placed. One order may
    produce many of these events — every leg in a multi-fill
    sequence emits its own [Trade_executed] IE. The event carries
    the trade itself only (quantity, price, fee); reconciling
    legs into a placement's running total is the consuming
    aggregate's job (the OrderTicket in execution_management),
    not the broker's.

    Published on [in-memory://broker.trade-executed] by the
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
    contract ({!Paper_broker_integration_events.Trade_executed_integration_event})
    for paper-mode runs. Both live publishers and the
    paper-broker simulator target the same URI on the bus, so
    the EM consumer is source-agnostic. *)

include module type of Trade_executed_integration_event_t
include module type of Trade_executed_integration_event_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t

type domain = Broker_domain.Remote_broker.Events.Trade_executed.t

val of_domain : correlation_id:string -> domain -> t
(** Project the domain event onto the wire IE.

    [correlation_id] is the saga-instance id — the application
    layer retrieves it from the broker's command log via
    [origin_correlation_id ~placement_id] before invoking the
    projection. It is not part of the domain event because the
    adapter has no knowledge of the saga that originated the
    submit. *)
