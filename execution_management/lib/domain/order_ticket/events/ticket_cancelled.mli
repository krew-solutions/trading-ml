(** Domain Event: ticket terminal — all outstanding placements
    settled (cancelled / rejected / unreachable / partially-filled)
    after a [Ticket_cancelling_started]. The [progress] field
    carries whatever cumulative fill landed before the cancel
    fully settled. *)

type t = {
  ticket_id : Values.Ticket_id.t;
  reason : Values.Cancel_reason.t;
  progress : Values.Progress.t;
  occurred_at : int64;
}

val make :
  ticket_id:Values.Ticket_id.t ->
  reason:Values.Cancel_reason.t ->
  progress:Values.Progress.t ->
  occurred_at:int64 ->
  t
