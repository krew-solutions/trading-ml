module Cmd = Execution_management_commands.Apply_placement_unreachable_command
module Workflow =
  Execution_management_commands.Apply_placement_unreachable_command_workflow

let handle
    ~store
    ~store_handle
    ~publish
    ~now
    ~ticket_id_of_placement_id
    (ie : Order_unreachable_integration_event.t) =
  let cmd : Cmd.t =
    {
      ticket_id = ticket_id_of_placement_id ie.placement_id;
      placement_id = ie.placement_id;
    }
  in
  match Workflow.execute ~store ~store_handle ~publish ~now cmd with
  | Ok () -> ()
  | Error _ -> ()
