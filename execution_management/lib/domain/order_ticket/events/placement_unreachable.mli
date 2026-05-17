(** Domain Event: transport / venue-side error prevented the
    placement from reaching market. Distinguished from
    [Placement_rejected] (which is venue refusal); compensation
    semantics typically match the rejected case. *)

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
