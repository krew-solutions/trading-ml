(** Command handler for {!Configure_risk_command.t}.

    Parses the wire-shape command into a validated
    {!Portfolio_management.Risk_config.t} and persists it into
    the per-book registry the unified handler consults. *)

type validation_error =
  | Invalid_book_id of string
  | Invalid_decimal of { field : string; value : string }
  | Invalid_fraction_range of string
  | Invalid_limits of string
  | Invalid_alpha_source_id of string
  | Invalid_instrument of { field : string; value : string }
  | Invalid_pair of string
  | Invalid_target_vol of string

val validation_error_to_string : validation_error -> string

type handle_error = Validation of validation_error

val handle_error_to_string : handle_error -> string
(** Human-readable rendering for HTTP / log surfaces. Tag-less:
    just the underlying validation message. *)

val handle :
  persist_risk_config:
    (Portfolio_management.Common.Book_id.t ->
    Portfolio_management.Risk_config.t ->
    unit) ->
  Configure_risk_command.t ->
  (unit, handle_error) Rop.t
(** Validate the wire command, build a
    {!Portfolio_management.Risk_config.t}, hand it to
    [persist_risk_config]. Errors aggregate via Rop's applicative
    so the caller can report all violations at once. *)
