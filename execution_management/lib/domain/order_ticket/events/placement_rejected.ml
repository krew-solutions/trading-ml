type t = {
  ticket_id : Values.Ticket_id.t;
  placement_id : Placement.Values.Placement_id.t;
  reason : string;
  occurred_at : int64;
}

let make ~ticket_id ~placement_id ~reason ~occurred_at =
  { ticket_id; placement_id; reason; occurred_at }
