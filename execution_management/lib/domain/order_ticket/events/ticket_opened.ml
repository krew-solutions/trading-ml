type t = {
  ticket_id : Values.Ticket_id.t;
  intent : Values.Trade_intent.t;
  directive : Values.Execution_directive.t;
  occurred_at : int64;
}

let make ~ticket_id ~intent ~directive ~occurred_at =
  { ticket_id; intent; directive; occurred_at }
