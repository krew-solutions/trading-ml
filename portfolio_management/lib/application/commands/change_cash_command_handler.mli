(** Command handler for {!Change_cash_command.t}. *)

type validation_error =
  | Invalid_book_id of string
  | Invalid_delta_format of string
  | Invalid_new_balance_format of string
  | Invalid_occurred_at of string

val validation_error_to_string : validation_error -> string

type validated_command = {
  book_id : Portfolio_management.Common.Book_id.t;
  delta : Decimal.t;
  new_balance : Decimal.t;
  occurred_at : int64;
}

type handle_error =
  | Validation of validation_error
  | Unknown_book of Portfolio_management.Common.Book_id.t

val handle :
  actual_portfolio_for:
    (Portfolio_management.Common.Book_id.t ->
    Portfolio_management.Actual_portfolio.t ref option) ->
  Change_cash_command.t ->
  (Portfolio_management.Actual_portfolio.Events.Actual_cash_changed.t, handle_error) Rop.t
