let execute
    ~(risk_view_ref_for :
       Pre_trade_risk.Common.Book_id.t -> Pre_trade_risk.Risk_view.t ref)
    (cmd : Record_fill_command.t) : (unit, Record_fill_command_handler.handle_error) Rop.t
    =
  match Record_fill_command_handler.handle ~risk_view_ref_for cmd with
  | Ok _event -> Rop.succeed ()
  | Error errs -> Error errs
