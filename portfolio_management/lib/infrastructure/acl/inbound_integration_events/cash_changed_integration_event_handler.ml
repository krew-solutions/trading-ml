module Cash_changed = Cash_changed_integration_event

let to_command (ev : Cash_changed.t) : Portfolio_management_commands.Change_cash_command.t
    =
  {
    book_id = ev.book_id;
    delta = ev.delta;
    new_balance = ev.new_balance;
    occurred_at = ev.occurred_at;
  }

let handle
    ~(dispatch_change_cash : Portfolio_management_commands.Change_cash_command.t -> unit)
    (ev : Cash_changed.t) : unit =
  dispatch_change_cash (to_command ev)
