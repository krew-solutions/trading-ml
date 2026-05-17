val execute :
  store:(module Execution_management_ports.Ticket_store.S with type t = 'store) ->
  store_handle:'store ->
  publish:(Execution_management.Order_ticket.event -> unit) ->
  now:(unit -> int64) ->
  Cancel_order_ticket_command.t ->
  (unit, Command_error.t) Rop.t
