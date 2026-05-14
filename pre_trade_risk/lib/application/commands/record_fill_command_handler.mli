(** Command handler for {!Record_fill_command.t}.

    Parse the wire-format command, then call
    {!Pre_trade_risk.Risk_view.commit_fill} on the shared
    {!Pre_trade_risk.Risk_view.t} ref keyed by [book_id]. The handler
    operates on a per-book registry of risk-view refs supplied by the
    composition root. *)

(** {1 Validation errors} *)

type validation_error =
  | Invalid_book_id of string
  | Invalid_symbol of string
  | Invalid_new_position_quantity of string
  | Invalid_new_avg_price of string
  | Invalid_new_cash of string
  | Invalid_occurred_at of string

val validation_error_to_string : validation_error -> string

(** {1 Validated form} *)

type validated_command = {
  book_id : Pre_trade_risk.Common.Book_id.t;
  instrument : Core.Instrument.t;
  new_position_quantity : Decimal.t;
  new_avg_price : Decimal.t;
  new_cash : Decimal.t;
  occurred_at : int64;
}

(** {1 Outcome} *)

type handle_error = Validation of validation_error

val handle :
  risk_view_ref_for:(Pre_trade_risk.Common.Book_id.t -> Pre_trade_risk.Risk_view.t ref) ->
  Record_fill_command.t ->
  (Pre_trade_risk.Risk_view.Events.Fill_recorded.t, handle_error) Rop.t
