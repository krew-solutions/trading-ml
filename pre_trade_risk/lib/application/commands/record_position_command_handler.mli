(** Handler for {!Record_position_command.t}. Validates the wire-format
    DTO into typed domain values and applies them to the
    book-keyed {!Pre_trade_risk.Risk_view.t} aggregate. *)

type validation_error =
  | Invalid_book_id of string
  | Invalid_symbol of string
  | Invalid_delta_qty of string
  | Invalid_new_qty of string
  | Invalid_avg_price of string
  | Invalid_occurred_at of string

val validation_error_to_string : validation_error -> string

type validated_command = {
  book_id : Pre_trade_risk.Common.Book_id.t;
  instrument : Core.Instrument.t;
  delta_qty : Decimal.t;
  new_qty : Decimal.t;
  avg_price : Decimal.t;
  occurred_at : int64;
}

type handle_error = Validation of validation_error

val handle :
  risk_view_ref_for:(Pre_trade_risk.Common.Book_id.t -> Pre_trade_risk.Risk_view.t ref) ->
  Record_position_command.t ->
  (Pre_trade_risk.Risk_view.Events.Position_recorded.t, handle_error) Rop.t
(** Mutates the book's [Risk_view.t ref] in place. The
    [risk_view_ref_for] port creates a fresh empty aggregate on first
    call for an unknown book — Risk_view's content is purely additive
    from upstream events, so missing-book is treated as
    "no-state-yet", not an error. *)
