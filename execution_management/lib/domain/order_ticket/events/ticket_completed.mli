(** Domain Event: ticket terminal — Σ filled = total. *)

type t = {
  ticket_id : Values.Ticket_id.t;
  progress : Values.Progress.t;
  occurred_at : int64;
}

val make :
  ticket_id:Values.Ticket_id.t ->
  progress:Values.Progress.t ->
  occurred_at:int64 ->
  t
