module Ot = Execution_management.Order_ticket

let handle ~ticket (cmd : Apply_placement_rejection_command.t) ~now =
  match Ot.Placement.Values.Placement_id.of_int cmd.placement_id with
  | exception Invalid_argument m ->
      Rop.fail (Command_error.Invalid_payload ("placement_id: " ^ m))
  | pid ->
      let t', events =
        Ot.on_placement_rejection ticket ~placement_id:pid ~reason:cmd.reason ~now
      in
      Rop.succeed (t', events)
