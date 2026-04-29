(** Account-side mirror of the Broker BC's "order rejected by
    upstream" integration event.

    Structurally identical wire shape to
    {!Broker_integration_events.Order_rejected_integration_event.t},
    but owned by Account so its compensation subscriber listens
    autonomously without importing types across the BC boundary.
    The bridge from Broker's outbound event to Account's mirror is
    an ACL adapter wired by the composition root.

    [reservation_id] is the cross-BC saga key (echoed back by Broker
    from the originating Submit command); Account uses it to release
    the matching reservation. *)

type t = { reservation_id : int; reason : string } [@@deriving yojson]
