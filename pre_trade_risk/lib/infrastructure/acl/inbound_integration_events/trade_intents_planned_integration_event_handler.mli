(** Handler for the inbound {!Trade_intents_planned_integration_event.t}.
    Translates each leg into an
    {!Pre_trade_risk_commands.Assess_trade_intent_command.t} and
    dispatches via the supplied port.

    Price for the assess command is synthesised from the most recent
    {!Pre_trade_risk.Risk_view.Values.Position_snapshot.avg_price} for
    the instrument; absent positions yield [Decimal.zero] which the
    gate rejects with ["zero price"]. *)

module Trade_intents_planned = Trade_intents_planned_integration_event

val handle :
  risk_view_for:(Pre_trade_risk.Common.Book_id.t -> Pre_trade_risk.Risk_view.t option) ->
  dispatch_assess:(Pre_trade_risk_commands.Assess_trade_intent_command.t -> unit) ->
  Trade_intents_planned.t ->
  unit
