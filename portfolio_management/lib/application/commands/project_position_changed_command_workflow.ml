let execute
    ~(actual_portfolio_for :
       Portfolio_management.Shared.Book_id.t ->
       Portfolio_management.Actual_portfolio.t ref option)
    (cmd : Project_position_changed_command.t) :
    (unit, Project_position_changed_command_handler.handle_error) Rop.t =
  match Project_position_changed_command_handler.handle ~actual_portfolio_for cmd with
  | Ok _domain_event -> Rop.succeed ()
  | Error errs -> Error errs
