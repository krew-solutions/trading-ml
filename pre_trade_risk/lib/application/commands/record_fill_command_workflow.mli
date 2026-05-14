(** ROP pipeline for {!Record_fill_command.t}. Runs the handler and
    discards the domain event — there is no outbound integration
    event for this commit (the change is purely internal to
    pre_trade_risk's [Risk_view] model). *)

val execute :
  risk_view_ref_for:(Pre_trade_risk.Common.Book_id.t -> Pre_trade_risk.Risk_view.t ref) ->
  Record_fill_command.t ->
  (unit, Record_fill_command_handler.handle_error) Rop.t
