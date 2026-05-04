module Direction_changed = Portfolio_management.Alpha_view.Events.Direction_changed

module Target_portfolio_updated =
  Portfolio_management_integration_events.Target_portfolio_updated_integration_event

let execute
    ~alpha_view_for
    ~subscribers_for
    ~notional_cap_for
    ~target_portfolio_for
    ~publish_target_portfolio_updated
    (cmd : Define_alpha_view_command.t) :
    (unit, Define_alpha_view_command_handler.handle_error) Rop.t =
  match Define_alpha_view_command_handler.handle ~alpha_view_for cmd with
  | Ok None -> Rop.succeed ()
  | Ok (Some direction_changed) ->
      Portfolio_management_domain_event_handlers
      .Apply_proposed_targets_on_alpha_direction_changed
      .handle ~subscribers_for ~notional_cap_for ~target_portfolio_for
        ~publish_target_portfolio_updated direction_changed;
      Rop.succeed ()
  | Error errs -> Error errs
