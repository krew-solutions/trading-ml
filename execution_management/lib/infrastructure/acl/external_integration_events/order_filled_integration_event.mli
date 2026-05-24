(** Mirror of {!Broker_integration_events.Order_filled_integration_event.t}
    — the broker BC's outbound per-leg fill IE, consumed by
    {!Order_filled_integration_event_handler} to feed
    {!Apply_placement_fill_command_workflow}. *)

include module type of Order_filled_integration_event_t

include module type of Order_filled_integration_event_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t
