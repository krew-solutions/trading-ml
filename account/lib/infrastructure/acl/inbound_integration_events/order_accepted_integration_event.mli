(** Account-side mirror of the Broker BC's "order accepted"
    integration event.

    Structurally identical wire shape to
    {!Broker_integration_events.Order_accepted_integration_event.t},
    but owned by Account so subscribers inside Account can listen
    autonomously without importing types across the BC boundary.
    The bridge from Broker's outbound event to Account's mirror is
    an ACL adapter wired by the composition root. *)

type t = { reservation_id : int; broker_order : Queries.Order_view_model.t }
[@@deriving yojson]
