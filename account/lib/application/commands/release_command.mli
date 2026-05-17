(** Inbound command to the Account BC: "release a previously
    earmarked reservation."

    Sent by the compensation choreography subscriber when Broker
    publishes {!Order_rejected.t} / {!Order_unreachable.t} carrying
    the matching [reservation_id]. The originating reservation was
    created by {!Reserve_command.t} on the same id.

    [correlation_id] propagates the saga-instance identifier from
    the {!Order_process_manager} Process Manager so audit / SSE can
    attribute the compensating release back to the originating
    saga; it is not consumed by the Account aggregate itself.

    The wire shape is generated from
    [shared/contracts/account/commands/release_command.atd]
    via atdgen. *)

include module type of Release_command_t

include module type of Release_command_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t
