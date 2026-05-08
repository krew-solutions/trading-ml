(** ROP pipeline for {!Record_position_command.t}. Wraps the handler;
    no outbound integration event today (telemetry-only domain event). *)

val execute :
  risk_view_ref_for:(Pre_trade_risk.Common.Book_id.t -> Pre_trade_risk.Risk_view.t ref) ->
  Record_position_command.t ->
  (unit, Record_position_command_handler.handle_error) Rop.t
