let execute ~persist_risk_config (cmd : Configure_risk_command.t) :
    (unit, Configure_risk_command_handler.handle_error) Rop.t =
  Configure_risk_command_handler.handle ~persist_risk_config cmd
