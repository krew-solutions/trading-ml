module Trade_intent_approved =
  Pre_trade_risk_integration_events.Trade_intent_approved_integration_event

module Trade_intent_rejected =
  Pre_trade_risk_integration_events.Trade_intent_rejected_integration_event

let execute
    ~(risk_view_for :
       Pre_trade_risk.Common.Book_id.t -> Pre_trade_risk.Risk_view.t option)
    ~(limits : Pre_trade_risk.Risk_limits.t)
    ~(mark : Core.Instrument.t -> Decimal.t option)
    ~(publish_approved : Trade_intent_approved.t -> unit)
    ~(publish_rejected : Trade_intent_rejected.t -> unit)
    (cmd : Assess_trade_intent_command.t) :
    (unit, Assess_trade_intent_command_handler.handle_error) Rop.t =
  match Assess_trade_intent_command_handler.handle ~risk_view_for ~limits ~mark cmd with
  | Ok (v, Pre_trade_risk.Assessment.Approve approved_qty) ->
      publish_approved
        Trade_intent_approved.
          {
            correlation_id = v.correlation_id;
            book_id = Pre_trade_risk.Common.Book_id.to_string v.book_id;
            symbol = Core.Instrument.to_qualified v.instrument;
            side = Core.Side.to_string v.side;
            quantity = Decimal.to_string approved_qty;
          };
      Rop.succeed ()
  | Ok (v, Pre_trade_risk.Assessment.Reject reason) ->
      publish_rejected
        Trade_intent_rejected.
          {
            correlation_id = v.correlation_id;
            book_id = Pre_trade_risk.Common.Book_id.to_string v.book_id;
            symbol = Core.Instrument.to_qualified v.instrument;
            side = Core.Side.to_string v.side;
            quantity = Decimal.to_string v.quantity;
            reason;
          };
      Rop.succeed ()
  | Error errs -> Error errs
