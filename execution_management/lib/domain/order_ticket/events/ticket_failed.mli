(** Domain Event: ticket terminal — strategy gave up (rejection
    cascade exceeded retry budget, etc.). Carries any partial
    progress accumulated before failure. *)

type t = {
  ticket_id : Values.Ticket_id.t;
  reason : string;
  progress : Values.Progress.t;
  occurred_at : int64;
}

val make :
  ticket_id:Values.Ticket_id.t ->
  reason:string ->
  progress:Values.Progress.t ->
  occurred_at:int64 ->
  t
