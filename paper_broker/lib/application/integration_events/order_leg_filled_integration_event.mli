(** Integration event: one fill leg was observed against a
    working order in paper_broker's book. Published on
    [in-memory://broker.order-leg-filled] after a successful
    [apply_bar_command_workflow] match. One order may produce
    multiple legs across consecutive bars (partial fills under
    a participation cap, IS-style slicing); each emits its
    own [Order_leg_filled] IE.

    Carries the actuals of this leg plus the cumulative new
    total filled, so Account / the EMS saga can commit the
    matching reservation atomically. *)

include module type of Order_leg_filled_integration_event_t
include module type of Order_leg_filled_integration_event_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t

type domain = Paper_broker.Order.Events.Order_filled.t

val of_domain : correlation_id:string -> domain -> t
