(** Domain Event: a placement received a fill (full or partial).
    Carries the fill record itself; the aggregate's [Progress.t]
    aggregates across placements. *)

type t = {
  ticket_id : Values.Ticket_id.t;
  placement_id : Placement.Values.Placement_id.t;
  fill : Placement.Values.Fill_record.t;
  occurred_at : int64;
}

val make :
  ticket_id:Values.Ticket_id.t ->
  placement_id:Placement.Values.Placement_id.t ->
  fill:Placement.Values.Fill_record.t ->
  occurred_at:int64 ->
  t
