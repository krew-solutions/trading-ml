module Ot = Execution_management.Order_ticket

let execute
    (type store)
    ~(store : (module Execution_management_ports.Ticket_store.S with type t = store))
    ~(store_handle : store)
    ~(publish : Ot.event -> unit)
    ~(now : unit -> int64)
    (cmd : Open_order_ticket_command.t) =
  let module S =
    (val store : Execution_management_ports.Ticket_store.S with type t = store)
  in
  match Open_order_ticket_command_handler.handle ~now:(now ()) cmd with
  | Error errs -> Error errs
  | Ok (t, events) ->
      S.put store_handle t;
      List.iter publish events;
      Rop.succeed (Ot.ticket_id t)
