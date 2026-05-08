(** Handler for {!Record_cash_command.t}. *)

type validation_error =
  | Invalid_book_id of string
  | Invalid_delta of string
  | Invalid_new_balance of string
  | Invalid_occurred_at of string

val validation_error_to_string : validation_error -> string

type validated_command = {
  book_id : Pre_trade_risk.Common.Book_id.t;
  delta : Decimal.t;
  new_balance : Decimal.t;
  occurred_at : int64;
}

type handle_error = Validation of validation_error

val handle :
  risk_view_ref_for:(Pre_trade_risk.Common.Book_id.t -> Pre_trade_risk.Risk_view.t ref) ->
  Record_cash_command.t ->
  (Pre_trade_risk.Risk_view.Events.Cash_recorded.t, handle_error) Rop.t
