type t = {
  ticket_id : Values.Ticket_id.t;
  reason : string;
  progress : Values.Progress.t;
  occurred_at : int64;
}

let make ~ticket_id ~reason ~progress ~occurred_at =
  { ticket_id; reason; progress; occurred_at }
