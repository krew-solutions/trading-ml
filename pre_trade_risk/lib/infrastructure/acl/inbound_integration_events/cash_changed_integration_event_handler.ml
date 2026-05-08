module Cash_changed = Cash_changed_integration_event

let handle
    ~(dispatch_record_cash : Pre_trade_risk_commands.Record_cash_command.t -> unit)
    (ev : Cash_changed.t) : unit =
  let cmd : Pre_trade_risk_commands.Record_cash_command.t =
    {
      book_id = ev.book_id;
      delta = ev.delta;
      new_balance = ev.new_balance;
      occurred_at = ev.occurred_at;
    }
  in
  dispatch_record_cash cmd
