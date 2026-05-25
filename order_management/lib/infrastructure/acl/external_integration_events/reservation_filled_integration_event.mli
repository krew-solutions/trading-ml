(** Mirror of {!Account_integration_events.Reservation_filled_integration_event.t}
    — Account's atomic fill fact. The saga consumes it as the
    terminal ack of the single Commit_fill_command it dispatched,
    reaching [Settled]. *)

include module type of Reservation_filled_integration_event_t
include module type of Reservation_filled_integration_event_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t
