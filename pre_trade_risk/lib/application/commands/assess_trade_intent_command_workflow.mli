(** ROP pipeline for {!Assess_trade_intent_command.t}. Wraps
    {!Assess_trade_intent_command_handler.handle} and shapes the
    outbound {!Trade_intent_approved_integration_event} or
    {!Trade_intent_rejected_integration_event} per the gate's outcome.

    A validation failure of the command itself produces no outbound
    IE — invalid wire input is a programming error in the upstream BC,
    not a saga step. The {!Order_process_manager} Process Manager will time
    out such instances rather than receiving an explicit ack. *)

module Trade_intent_approved =
  Pre_trade_risk_integration_events.Trade_intent_approved_integration_event

module Trade_intent_rejected =
  Pre_trade_risk_integration_events.Trade_intent_rejected_integration_event

val execute :
  risk_view_for:(Pre_trade_risk.Common.Book_id.t -> Pre_trade_risk.Risk_view.t option) ->
  limits:Pre_trade_risk.Risk_limits.t ->
  mark:(Core.Instrument.t -> Decimal.t option) ->
  publish_approved:(Trade_intent_approved.t -> unit) ->
  publish_rejected:(Trade_intent_rejected.t -> unit) ->
  Assess_trade_intent_command.t ->
  (unit, Assess_trade_intent_command_handler.handle_error) Rop.t
