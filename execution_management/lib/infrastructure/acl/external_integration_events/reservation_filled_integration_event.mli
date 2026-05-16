(** EMS-side mirror of Account's [Reservation_filled_integration_event].

    Consumed by the kill-switch peak-equity tracker — only the
    [new_cash] field is used today (as an equity proxy until a
    mark-to-market feed lands).

    Wire shape regenerated from the producer's .atd contract. *)

include module type of Reservation_filled_integration_event_t
include module type of Reservation_filled_integration_event_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t
