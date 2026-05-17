type t = {
  ticket_id : Values.Ticket_id.t;
  progress : Values.Progress.t;
  occurred_at : int64;
}

let make ~ticket_id ~progress ~occurred_at =
  { ticket_id; progress; occurred_at }
