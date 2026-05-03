(** Command handler for {!Reconcile_command.t}.

    Runs {!Portfolio_management.Reconciliation.diff_with_event} against
    the supplied per-book target / actual lookup pair. *)

type validation_error = Invalid_book_id of string | Invalid_computed_at of string

val validation_error_to_string : validation_error -> string

type validated_command = {
  book_id : Portfolio_management.Shared.Book_id.t;
  computed_at : int64;
}

type handle_error =
  | Validation of validation_error
  | Unknown_book of Portfolio_management.Shared.Book_id.t

val handle :
  target_portfolio_for:
    (Portfolio_management.Shared.Book_id.t ->
    Portfolio_management.Target_portfolio.t option) ->
  actual_portfolio_for:
    (Portfolio_management.Shared.Book_id.t ->
    Portfolio_management.Actual_portfolio.t option) ->
  Reconcile_command.t ->
  (Portfolio_management.Reconciliation.Events.Trades_planned.t, handle_error) Rop.t
