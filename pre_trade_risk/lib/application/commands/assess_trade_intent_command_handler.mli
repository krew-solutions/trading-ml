(** Command handler for {!Assess_trade_intent_command.t}.
    Validates the wire-format DTO into typed domain values, looks up
    the BC's {!Pre_trade_risk.Risk_view.t} for the supplied book, and
    delegates the gate decision to {!Pre_trade_risk.Assessment.assess}.

    Read-only on the aggregate: assessment does not mutate
    [Risk_view.t]; the only state changes in this BC come from
    {!Record_position_command} / {!Record_cash_command}. *)

type validation_error =
  | Invalid_book_id of string
  | Invalid_symbol of string
  | Invalid_side of string
  | Invalid_quantity_format of string
  | Non_positive_quantity of string
  | Invalid_price_format of string
  | Negative_price of string
  | Empty_correlation_id

val validation_error_to_string : validation_error -> string

type validated_command = {
  correlation_id : string;
  book_id : Pre_trade_risk.Common.Book_id.t;
  instrument : Core.Instrument.t;
  side : Core.Side.t;
  quantity : Decimal.t;
  price : Decimal.t;
}

type handle_error =
  | Validation of validation_error
  | Unknown_book of Pre_trade_risk.Common.Book_id.t

val handle :
  risk_view_for:(Pre_trade_risk.Common.Book_id.t -> Pre_trade_risk.Risk_view.t option) ->
  limits:Pre_trade_risk.Risk_limits.t ->
  mark:(Core.Instrument.t -> Decimal.t option) ->
  Assess_trade_intent_command.t ->
  (validated_command * Pre_trade_risk.Assessment.outcome, handle_error) Rop.t
(** Returns the validated command paired with the assessment outcome
    so the workflow can shape both [Trade_intent_approved] and
    [Trade_intent_rejected] integration events without re-parsing. *)
