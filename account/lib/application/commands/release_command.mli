(** Inbound command to the Account BC: "release a previously
    earmarked reservation."

    Sent by the compensation choreography subscriber when Broker
    publishes {!Order_rejected.t} / {!Order_unreachable.t} carrying
    the matching [reservation_id]. The originating reservation was
    created by {!Reserve_command.t} on the same id. *)

type t = { reservation_id : int } [@@deriving yojson]
