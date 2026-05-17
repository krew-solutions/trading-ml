type t = {
  ticket_id : Values.Ticket_id.t;
  placement_id : Placement.Values.Placement_id.t;
  fill : Placement.Values.Fill_record.t;
  occurred_at : int64;
}

let make ~ticket_id ~placement_id ~fill ~occurred_at =
  { ticket_id; placement_id; fill; occurred_at }
