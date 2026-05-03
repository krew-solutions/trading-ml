let execute
    ~(actual_portfolio_for :
       Portfolio_management.Shared.Book_id.t ->
       Portfolio_management.Actual_portfolio.t ref option)
    (cmd : Change_cash_command.t) : (unit, Change_cash_command_handler.handle_error) Rop.t
    =
  match Change_cash_command_handler.handle ~actual_portfolio_for cmd with
  | Ok _domain_event -> Rop.succeed ()
  | Error errs -> Error errs
