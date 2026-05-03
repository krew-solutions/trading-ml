(** Command handler for {!Change_position_command.t}.

    Parse the wire-format command, then call
    {!Portfolio_management.Actual_portfolio.apply_position_change}
    on the shared actual_portfolio ref keyed by [book_id]. The handler
    operates on a per-book table of actual_portfolio refs supplied by
    the composition root. *)

(** {1 Validation errors} *)

type validation_error =
  | Invalid_book_id of string
  | Invalid_instrument of string
  | Invalid_delta_qty_format of string
  | Invalid_new_qty_format of string
  | Invalid_avg_price_format of string
  | Negative_avg_price of string
  | Invalid_occurred_at of string

val validation_error_to_string : validation_error -> string

(** {1 Validated form} *)

type validated_command = {
  book_id : Portfolio_management.Shared.Book_id.t;
  instrument : Core.Instrument.t;
  delta_qty : Decimal.t;
  new_qty : Decimal.t;
  avg_price : Decimal.t;
  occurred_at : int64;
}

(** {1 Outcome} *)

type handle_error =
  | Validation of validation_error
  | Unknown_book of Portfolio_management.Shared.Book_id.t
      (** No actual_portfolio is registered for the book. *)

val handle :
  actual_portfolio_for:
    (Portfolio_management.Shared.Book_id.t ->
    Portfolio_management.Actual_portfolio.t ref option) ->
  Change_position_command.t ->
  ( Portfolio_management.Actual_portfolio.Events.Actual_position_changed.t,
    handle_error )
  Rop.t
