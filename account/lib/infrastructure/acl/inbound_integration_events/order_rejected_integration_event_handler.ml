module Order_rejected = Order_rejected_integration_event

let handle
    ~(dispatch_release : Account_commands.Release_command.t -> unit)
    (ev : Order_rejected.t) : unit =
  let cmd : Account_commands.Release_command.t =
    { correlation_id = ev.correlation_id; reservation_id = ev.reservation_id }
  in
  dispatch_release cmd
