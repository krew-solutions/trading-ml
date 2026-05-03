module Cash_changed = Cash_changed_integration_event

module Make (Bus : Bus.Event_bus.S) = struct
  let to_command (ev : Cash_changed.t) :
      Portfolio_management_commands.Project_cash_changed_command.t =
    {
      book_id = ev.book_id;
      delta = ev.delta;
      new_balance = ev.new_balance;
      occurred_at = ev.occurred_at;
    }

  let attach
      ~(events : Cash_changed.t Bus.t)
      ~(dispatch_project_cash_changed :
         Portfolio_management_commands.Project_cash_changed_command.t -> unit) :
      Bus.subscription =
    Bus.subscribe events (fun ev -> dispatch_project_cash_changed (to_command ev))
end
