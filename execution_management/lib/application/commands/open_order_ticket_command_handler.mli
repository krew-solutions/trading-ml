(** Pure parsing + domain-operation step for
    {!Open_order_ticket_command.t}. Translates wire primitives
    to typed VOs, invokes {!Order_ticket.open_ticket}, and
    returns the constructed aggregate paired with the emitted
    events. Does NOT touch the store — the workflow handles
    persistence. *)

val resolve_directive :
  Open_order_ticket_command.directive option ->
  (Execution_management.Order_ticket.Values.Execution_directive.t, Command_error.t) result
(** Maps the optional wire-shape directive (kind + opaque JSON
    params blob) to the typed
    {!Order_ticket.Values.Execution_directive.t}. [None] falls
    back to {!Order_ticket.Values.Execution_policy.default}
    (Immediate). Exposed for unit tests covering the parser
    branches; the workflow path goes through [handle]. *)

val handle :
  now:int64 ->
  Open_order_ticket_command.t ->
  ( Execution_management.Order_ticket.t * Execution_management.Order_ticket.event list,
    Command_error.t )
  Rop.t
