type t = {
  ticket_id : Values.Ticket_id.t;
  reason : Values.Cancel_reason.t;
  progress : Values.Progress.t;
  occurred_at : int64;
}

let make ~ticket_id ~reason ~progress ~occurred_at =
  { ticket_id; reason; progress; occurred_at }
