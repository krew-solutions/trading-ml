module Cmd = Execution_management_commands.Apply_placement_fill_command
module Workflow = Execution_management_commands.Apply_placement_fill_command_workflow

let handle
    ~store
    ~store_handle
    ~publish
    ~now
    ~ticket_id_of_placement_id
    (ie : Trade_executed_integration_event.t) =
  let cmd : Cmd.t =
    {
      ticket_id = ticket_id_of_placement_id ie.placement_id;
      placement_id = ie.placement_id;
      fill_quantity = ie.quantity;
      fill_price = ie.price;
      fee = ie.fee;
      fill_ts = (try Datetime.Iso8601.parse ie.ts with _ -> 0L);
    }
  in
  match Workflow.execute ~store ~store_handle ~publish ~now cmd with
  | Ok () -> ()
  | Error _ -> ()
