(** Command: transport failure on a placement. Issued in-process
    by the ACL handler for {!Broker.Order_unreachable_integration_event}. *)

type t = { ticket_id : int; placement_id : int }
