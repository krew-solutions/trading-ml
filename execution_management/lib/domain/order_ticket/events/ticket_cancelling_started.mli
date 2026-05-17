(** Domain Event: operator-initiated cancel observed; aggregate
    transitioned Working → Cancelling. Carries the list of
    outstanding placements whose broker-side cancel must be
    dispatched. *)

type t = {
  ticket_id : Values.Ticket_id.t;
  reason : Values.Cancel_reason.t;
  outstanding_placements : Placement.Values.Placement_id.t list;
  occurred_at : int64;
}

val make :
  ticket_id:Values.Ticket_id.t ->
  reason:Values.Cancel_reason.t ->
  outstanding_placements:Placement.Values.Placement_id.t list ->
  occurred_at:int64 ->
  t
