module Cmd = Execution_management_commands.Apply_placement_rejection_command
module Workflow = Execution_management_commands.Apply_placement_rejection_command_workflow

let handle
    ~store
    ~store_handle
    ~publish
    ~now
    ~ticket_id_of_placement_id
    (ie : Order_rejected_integration_event.t) =
  let cmd : Cmd.t =
    {
      ticket_id = ticket_id_of_placement_id ie.placement_id;
      placement_id = ie.placement_id;
      reason = ie.reason;
    }
  in
  match Workflow.execute ~store ~store_handle ~publish ~now cmd with
  | Ok () -> ()
  | Error _ -> ()
