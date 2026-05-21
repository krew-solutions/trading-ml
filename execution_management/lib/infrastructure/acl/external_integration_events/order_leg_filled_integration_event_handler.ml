module Cmd = Execution_management_commands.Apply_placement_leg_fill_command
module Workflow = Execution_management_commands.Apply_placement_leg_fill_command_workflow

let handle
    ~store
    ~store_handle
    ~publish
    ~now
    ~ticket_id_of_placement_id
    (ie : Order_leg_filled_integration_event.t) =
  let cmd : Cmd.t =
    {
      ticket_id = ticket_id_of_placement_id ie.placement_id;
      placement_id = ie.placement_id;
      fill_quantity = ie.fill_quantity;
      fill_price = ie.fill_price;
      fee = ie.fee;
      fill_ts = (try Datetime.Iso8601.parse ie.fill_ts with _ -> 0L);
    }
  in
  match Workflow.execute ~store ~store_handle ~publish ~now cmd with
  | Ok () -> ()
  | Error _ -> ()
