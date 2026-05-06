module Target_portfolio_updated =
  Portfolio_management_integration_events.Target_portfolio_updated_integration_event

let handle
    ~(publish_target_portfolio_updated : Target_portfolio_updated.t -> unit)
    (ev : Portfolio_management.Target_portfolio.Events.Target_set.t) : unit =
  publish_target_portfolio_updated (Target_portfolio_updated.of_domain ev)
