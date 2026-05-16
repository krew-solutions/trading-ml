(** PM-side mirror of Account's [Reservation_filled_integration_event].

    Carries the full transactional effect of a reservation maturing
    into a fill — both the new cash balance and the new position
    snapshot — in one atomic payload, so PM can commit them
    together via {!Commit_actual_fill_command} without ever exposing
    a transient state that violates [equity = cash + Σ qty × mark].

    Wire shape regenerated from Account's .atd contract; structural
    drift between producer and consumer is a compile-time error. *)

include module type of Reservation_filled_integration_event_t
include module type of Reservation_filled_integration_event_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t
