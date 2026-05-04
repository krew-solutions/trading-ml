(** Command handler for {!Define_alpha_view_command.t}.

    Responsibilities (single phase, validation private):
    - parse wire-format strings into PM-domain types;
    - look up / create the [Alpha_view] aggregate by
      [(alpha_source_id, instrument)] from a composition-root-supplied
      registry of refs;
    - invoke {!Portfolio_management.Alpha_view.define};
    - mutate the aggregate ref;
    - return the optional [Direction_changed] domain event on the
      success track for the workflow to fan out. *)

(** {1 Validation errors} *)

type validation_error =
  | Invalid_alpha_source_id of string
  | Invalid_instrument of string
  | Invalid_direction of string
  | Invalid_strength of float
  | Invalid_price_format of string
  | Negative_price of string
  | Invalid_occurred_at of string

val validation_error_to_string : validation_error -> string

(** {1 Validated form} *)

type validated_define_alpha_view_command = {
  alpha_source_id : Portfolio_management.Common.Alpha_source_id.t;
  instrument : Core.Instrument.t;
  direction : Portfolio_management.Common.Direction.t;
  strength : float;
  price : Decimal.t;
  occurred_at : int64;
}

(** {1 Outcome} *)

type handle_error = Validation of validation_error

val handle :
  alpha_view_for:
    (alpha_source_id:Portfolio_management.Common.Alpha_source_id.t ->
    instrument:Core.Instrument.t ->
    Portfolio_management.Alpha_view.t ref) ->
  Define_alpha_view_command.t ->
  (Portfolio_management.Alpha_view.Events.Direction_changed.t option, handle_error) Rop.t
(** [alpha_view_for] is a composition-root-supplied lookup that
    returns (creating-on-demand) the [Alpha_view.t ref] for the
    given key. Tests inject an in-memory [Hashtbl]-backed lookup. *)
