module Ot = Execution_management.Order_ticket

let handle ~ticket ~now = Ot.on_clock_tick ticket ~now
