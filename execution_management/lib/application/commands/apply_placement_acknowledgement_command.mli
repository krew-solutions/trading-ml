(** Command: broker acknowledged a placement. Issued in-process
    by the ACL handler for {!Broker.Order_accepted_integration_event}. *)

type t = { ticket_id : int; placement_id : int }
