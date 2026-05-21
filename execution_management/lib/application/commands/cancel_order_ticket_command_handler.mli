val handle :
  ticket:Execution_management.Order_ticket.t ->
  Cancel_order_ticket_command.t ->
  now:int64 ->
  ( Execution_management.Order_ticket.t * Execution_management.Order_ticket.event list,
    Command_error.t )
  Rop.t
