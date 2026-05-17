(** Command: broker rejected a placement. Issued in-process by
    the ACL handler for {!Broker.Order_rejected_integration_event}. *)

type t = { ticket_id : int; placement_id : int; reason : string }
