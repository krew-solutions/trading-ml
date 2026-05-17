(** Pure parsing + domain-operation step for
    {!Open_order_ticket_command.t}. Translates wire primitives
    to typed VOs, invokes {!Order_ticket.open_ticket}, and
    returns the constructed aggregate paired with the emitted
    events. Does NOT touch the store — the workflow handles
    persistence. *)

val handle :
  now:int64 ->
  Open_order_ticket_command.t ->
  (Execution_management.Order_ticket.t
   * Execution_management.Order_ticket.event list,
   Command_error.t)
  Rop.t
