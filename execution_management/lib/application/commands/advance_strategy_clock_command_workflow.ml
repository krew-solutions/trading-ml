module Ot = Execution_management.Order_ticket

let execute
    (type store)
    ~(store : (module Execution_management_ports.Ticket_store.S with type t = store))
    ~(store_handle : store)
    ~(publish : Ot.event -> unit)
    ~(now : unit -> int64)
    (cmd : Advance_strategy_clock_command.t) =
  let module S =
    (val store : Execution_management_ports.Ticket_store.S with type t = store)
  in
  match Ot.Values.Ticket_id.of_int cmd.ticket_id with
  | exception Invalid_argument m ->
      Rop.fail (Command_error.Invalid_payload ("ticket_id: " ^ m))
  | tid -> (
      match S.get store_handle tid with
      | None -> Rop.fail (Command_error.Ticket_not_found cmd.ticket_id)
      | Some ticket ->
          let t', events =
            Advance_strategy_clock_command_handler.handle ~ticket ~now:(now ())
          in
          S.put store_handle t';
          List.iter publish events;
          Rop.succeed ())
