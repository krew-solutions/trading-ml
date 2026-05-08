(** ROP pipeline for {!Record_cash_command.t}. *)

val execute :
  risk_view_ref_for:(Pre_trade_risk.Common.Book_id.t -> Pre_trade_risk.Risk_view.t ref) ->
  Record_cash_command.t ->
  (unit, Record_cash_command_handler.handle_error) Rop.t
