module Order_unreachable = Order_unreachable_integration_event

let handle
    ~(dispatch_release : Account_commands.Release_command.t -> unit)
    (ev : Order_unreachable.t) : unit =
  let cmd : Account_commands.Release_command.t =
    { correlation_id = ev.correlation_id; reservation_id = ev.reservation_id }
  in
  dispatch_release cmd
