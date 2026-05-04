module Trade_intents_planned =
  Portfolio_management_integration_events.Trade_intents_planned_integration_event

let execute
    ~(target_portfolio_for :
       Portfolio_management.Common.Book_id.t ->
       Portfolio_management.Target_portfolio.t option)
    ~(actual_portfolio_for :
       Portfolio_management.Common.Book_id.t ->
       Portfolio_management.Actual_portfolio.t option)
    ~(publish_trade_intents_planned : Trade_intents_planned.t -> unit)
    (cmd : Reconcile_command.t) : (unit, Reconcile_command_handler.handle_error) Rop.t =
  match
    Reconcile_command_handler.handle ~target_portfolio_for ~actual_portfolio_for cmd
  with
  | Ok domain_event ->
      Portfolio_management_domain_event_handlers
      .Publish_integration_event_on_trades_planned
      .handle ~publish_trade_intents_planned domain_event;
      Rop.succeed ()
  | Error errs -> Error errs
