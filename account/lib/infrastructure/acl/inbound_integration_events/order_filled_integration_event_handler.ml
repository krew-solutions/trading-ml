module Order_filled = Order_filled_integration_event

let handle
    ~(dispatch_commit_fill : Account_commands.Commit_fill_command.t -> unit)
    (ev : Order_filled.t) : unit =
  let cmd : Account_commands.Commit_fill_command.t =
    {
      correlation_id = ev.correlation_id;
      reservation_id = ev.reservation_id;
      quantity = ev.quantity;
      price = ev.price;
      fee = ev.fee;
    }
  in
  dispatch_commit_fill cmd
