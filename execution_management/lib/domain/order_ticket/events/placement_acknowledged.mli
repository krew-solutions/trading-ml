(** Domain Event: broker acknowledged receipt of a placement
    (transitioned Pending → Working at the venue). *)

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
