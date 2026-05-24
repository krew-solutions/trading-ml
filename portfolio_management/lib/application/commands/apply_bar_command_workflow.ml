module Target_portfolio = Portfolio_management.Target_portfolio
module Common = Portfolio_management.Common

module Target_portfolio_updated =
  Portfolio_management_integration_events.Target_portfolio_updated_integration_event

let execute
    ~(pair_mr_states_for :
       Core.Instrument.t -> Portfolio_management.Pair_mean_reversion.state ref list)
    ~(pair_kalman_mr_states_for :
       Core.Instrument.t -> Portfolio_management.Pair_kalman_mean_reversion.state ref list)
    ~(update_mark : Core.Instrument.t -> close:Decimal.t -> unit)
    ~(update_vol : Core.Instrument.t -> close:Decimal.t -> unit)
    ~risk_config_for
    ~total_equity_for
    ~mark_for
    ~volatility_for
    ~sizing_for
    ~target_portfolio_for
    ~publish_target_portfolio_updated
    (cmd : Apply_bar_command.t) : (unit, Apply_bar_command_handler.handle_error) Rop.t =
  match
    Apply_bar_command_handler.handle ~pair_mr_states_for ~pair_kalman_mr_states_for cmd
  with
  | Ok { intents; mark = instrument, close } ->
      update_mark instrument ~close;
      update_vol instrument ~close;
      List.iter
        (fun intent ->
          Portfolio_management_domain_event_handlers.Build_target_on_construction_intent
          .handle ~risk_config_for ~total_equity_for ~mark_for ~volatility_for ~sizing_for
            ~target_portfolio_for ~publish_target_portfolio_updated intent)
        intents;
      Rop.succeed ()
  | Error errs -> Error errs
