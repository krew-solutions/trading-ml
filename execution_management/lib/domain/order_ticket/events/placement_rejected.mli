(** Domain Event: broker refused a placement at submission. *)

type t = {
  ticket_id : Values.Ticket_id.t;
  placement_id : Placement.Values.Placement_id.t;
  reason : string;
  occurred_at : int64;
}

val make :
  ticket_id:Values.Ticket_id.t ->
  placement_id:Placement.Values.Placement_id.t ->
  reason:string ->
  occurred_at:int64 ->
  t
