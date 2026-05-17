(** Command: broker confirmed a cancellation. Issued in-process
    by the ACL handler for {!Broker.Order_cancelled_integration_event}. *)

type t = { ticket_id : int; placement_id : int }
