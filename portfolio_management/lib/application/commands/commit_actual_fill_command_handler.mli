(** Command handler for {!Commit_actual_fill_command.t}.

    Parse the wire-format command, then call
    {!Portfolio_management.Actual_portfolio.commit_fill} on the
    shared actual_portfolio ref keyed by [book_id]. The handler
    operates on a per-book table of actual_portfolio refs supplied by
    the composition root. *)

(** {1 Validation errors} *)

type validation_error =
  | Invalid_book_id of string
  | Invalid_instrument of string
  | Invalid_new_position_quantity_format of string
  | Invalid_new_avg_price_format of string
  | Negative_new_avg_price of string
  | Invalid_new_cash_format of string
  | Invalid_occurred_at of string

val validation_error_to_string : validation_error -> string

(** {1 Validated form} *)

type validated_command = {
  book_id : Portfolio_management.Common.Book_id.t;
  instrument : Core.Instrument.t;
  new_position_quantity : Decimal.t;
  new_avg_price : Decimal.t;
  new_cash : Decimal.t;
  occurred_at : int64;
}

(** {1 Outcome} *)

type handle_error =
  | Validation of validation_error
  | Unknown_book of Portfolio_management.Common.Book_id.t
      (** No actual_portfolio is registered for the book. *)

val handle :
  actual_portfolio_for:
    (Portfolio_management.Common.Book_id.t ->
    Portfolio_management.Actual_portfolio.t ref option) ->
  Commit_actual_fill_command.t ->
  ( Portfolio_management.Actual_portfolio.Events.Actual_fill_committed.t,
    handle_error )
  Rop.t
