module Target_portfolio_updated =
  Portfolio_management_integration_events.Target_portfolio_updated_integration_event

let execute
    ~(target_portfolio : Portfolio_management.Target_portfolio.t ref)
    ~(publish_target_portfolio_updated : Target_portfolio_updated.t -> unit)
    (cmd : Set_target_command.t) : (unit, Set_target_command_handler.handle_error) Rop.t =
  match Set_target_command_handler.handle ~target_portfolio cmd with
  | Ok domain_event ->
      Portfolio_management_domain_event_handlers.Publish_integration_event_on_target_set
      .handle ~publish_target_portfolio_updated domain_event;
      Rop.succeed ()
  | Error errs -> Error errs
