module Ot = Execution_management.Order_ticket
module Ports = Execution_management_ports

let handle
    (type s)
    (module Store : Ports.Ticket_store.S with type t = s)
    ~(store_handle : s)
    (q : Get_order_ticket_query.t) : Order_ticket_view_model.t option =
  let ticket_id =
    try Some (Ot.Values.Ticket_id.of_int q.ticket_id) with Invalid_argument _ -> None
  in
  match ticket_id with
  | None -> None
  | Some tid -> Option.map Order_ticket_view_model.of_domain (Store.get store_handle tid)
