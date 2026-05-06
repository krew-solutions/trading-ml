(** Command handler for {!Set_target_command.t}.

    Accepts the wire-format command directly: parse, route to the
    target_portfolio aggregate's [apply_proposal], mutate the shared
    target_portfolio ref, yield the resulting domain event.

    Validation is intentionally a private internal phase — see the
    rationale in [account_commands/reserve_command_handler.mli]. *)

(** {1 Validation errors} *)

type validation_error =
  | Invalid_book_id of string
  | Invalid_source of string
  | Invalid_proposed_at of string
  | Invalid_instrument of string
  | Invalid_target_qty_format of string

val validation_error_to_string : validation_error -> string

val apply_error_to_string : Portfolio_management.Target_portfolio.apply_error -> string

(** {1 Validated form} *)

type validated_position = { instrument : Core.Instrument.t; target_qty : Decimal.t }

type validated_set_target_command = {
  book_id : Portfolio_management.Common.Book_id.t;
  source : string;
  proposed_at : int64;
  positions : validated_position list;
}

(** {1 Outcome} *)

type handle_error =
  | Validation of validation_error
  | Apply of {
      attempted : validated_set_target_command;
      error : Portfolio_management.Target_portfolio.apply_error;
    }

val handle :
  target_portfolio:Portfolio_management.Target_portfolio.t ref ->
  Set_target_command.t ->
  (Portfolio_management.Target_portfolio.Events.Target_set.t, handle_error) Rop.t
(** Parse, validate, apply, yield event. Returns the domain event on
    Ok, a discriminated error on Error. *)
