(** Integration event: paper_broker refused a submit_order_command
    at the wire / validation boundary (malformed symbol, invalid
    kind/tif, non-positive quantity, etc.). Published on
    [in-memory://broker.order-rejected].

    Distinct from "broker rejected the order at the venue" — for
    paper_broker, this fires when the request never enters the
    book in the first place.

    The wire shape is the broker BC's canonical contract,
    generated from
    [shared/contracts/broker/integration_events/order_rejected_integration_event.atd]
    via atdgen. paper_broker emits per this contract as one
    implementation of the broker abstraction (see ADR-0015). *)

include module type of Order_rejected_integration_event_t

include module type of Order_rejected_integration_event_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t
