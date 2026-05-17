val handle :
  store:(module Execution_management_ports.Ticket_store.S with type t = 'store) ->
  store_handle:'store ->
  publish:(Execution_management.Order_ticket.event -> unit) ->
  now:(unit -> int64) ->
  ticket_id_of_placement_id:(int -> int) ->
  Order_unreachable_integration_event.t ->
  unit
