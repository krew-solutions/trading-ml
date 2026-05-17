(** Domain Event: an OrderTicket was opened against an approved
    trader intent. Fires once per ticket lifecycle. *)

type t = {
  ticket_id : Values.Ticket_id.t;
  intent : Values.Trade_intent.t;
  directive : Values.Execution_directive.t;
  occurred_at : int64;
}

val make :
  ticket_id:Values.Ticket_id.t ->
  intent:Values.Trade_intent.t ->
  directive:Values.Execution_directive.t ->
  occurred_at:int64 ->
  t
