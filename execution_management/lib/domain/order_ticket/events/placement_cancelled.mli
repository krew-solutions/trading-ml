(** Domain Event: broker confirmed a cancellation of a placement. *)

type t = {
  ticket_id : Values.Ticket_id.t;
  placement_id : Placement.Values.Placement_id.t;
  occurred_at : int64;
}

val make :
  ticket_id:Values.Ticket_id.t ->
  placement_id:Placement.Values.Placement_id.t ->
  occurred_at:int64 ->
  t
