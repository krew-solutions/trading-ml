(** Account-side mirror of the Broker BC's "broker unreachable"
    integration event.

    Structurally identical wire shape to
    {!Broker_integration_events.Order_unreachable_integration_event.t},
    but owned by Account so its compensation subscriber listens
    autonomously without importing types across the BC boundary.
    The bridge from Broker's outbound event to Account's mirror is
    an ACL adapter wired by the composition root. *)

type t = { reservation_id : int; reason : string } [@@deriving yojson]
