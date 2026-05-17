module Ot = Execution_management.Order_ticket

let parse_reason = function
  | "operator" | "Operator" -> Ok Ot.Values.Cancel_reason.Operator
  | "kill_switch" | "Kill_switch" -> Ok Ot.Values.Cancel_reason.Kill_switch
  | "risk_limit_breach" | "Risk_limit_breach" ->
      Ok Ot.Values.Cancel_reason.Risk_limit_breach
  | s -> Error (Command_error.Invalid_payload ("unknown cancel reason: " ^ s))

let handle ~ticket (cmd : Cancel_order_ticket_command.t) ~now =
  match parse_reason cmd.reason with
  | Error e -> Rop.fail e
  | Ok reason ->
      let t', events = Ot.cancel ticket ~reason ~now in
      Rop.succeed (t', events)
