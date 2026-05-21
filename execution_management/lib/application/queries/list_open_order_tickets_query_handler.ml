module Ports = Execution_management_ports

let handle
    (type s)
    (module Store : Ports.Ticket_store.S with type t = s)
    ~(store_handle : s)
    (_q : List_open_order_tickets_query.t) : Order_ticket_view_model.t list =
  Store.all_open store_handle |> List.map Order_ticket_view_model.of_domain
