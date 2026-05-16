(** Integration event: paper_broker accepted a freshly-submitted order
    into its working book. Published on
    [in-memory://broker.order-accepted] after a successful
    [submit_order_command_workflow].

    The downstream EMS saga transitions
    [Awaiting_reservation → Submitted] on this.

    The wire shape is the broker BC's canonical contract,
    generated from
    [shared/contracts/broker/integration_events/order_accepted_integration_event.atd]
    via atdgen. paper_broker emits per this contract as one
    implementation of the broker abstraction (ADR-0015); rich
    projection state (id, instrument, side, quantity, created_ts)
    available on the [Paper_broker.Order.Events.Order_accepted]
    domain event is intentionally dropped on the wire — the
    consumer (execution_management) addresses placements by
    [placement_id] and already holds (instrument, side, quantity)
    on its own Placement aggregate. *)

include module type of Order_accepted_integration_event_t
include module type of Order_accepted_integration_event_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t

type domain = Paper_broker.Order.Events.Order_accepted.t

val of_domain : correlation_id:string -> domain -> t
