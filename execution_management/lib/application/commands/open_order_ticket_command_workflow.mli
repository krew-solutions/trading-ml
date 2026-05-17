(** Workflow for {!Open_order_ticket_command.t}.

    Composes {!Open_order_ticket_command_handler.handle} with
    persistence and event publishing:
    1. Parse the command + run {!Order_ticket.open_ticket}.
    2. Persist the fresh aggregate via {!Ticket_store.S.put}.
    3. Invoke the [publish] callback with each emitted event.

    Errors short-circuit: a parse failure prevents the store
    write. *)

val execute :
  store:(module Execution_management_ports.Ticket_store.S with type t = 'store) ->
  store_handle:'store ->
  publish:(Execution_management.Order_ticket.event -> unit) ->
  now:(unit -> int64) ->
  Open_order_ticket_command.t ->
  (Execution_management.Order_ticket.Values.Ticket_id.t, Command_error.t) Rop.t
