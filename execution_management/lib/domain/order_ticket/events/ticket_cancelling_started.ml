type t = {
  ticket_id : Values.Ticket_id.t;
  reason : Values.Cancel_reason.t;
  outstanding_placements : Placement.Values.Placement_id.t list;
  occurred_at : int64;
}

let make ~ticket_id ~reason ~outstanding_placements ~occurred_at =
  { ticket_id; reason; outstanding_placements; occurred_at }
