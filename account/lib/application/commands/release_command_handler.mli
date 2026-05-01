(** Command handler for {!Release_command.t}.

    Symmetric with {!Reserve_command_handler}: accepts the
    wire-format command, validates internally, invokes
    {!Account.Portfolio.try_release}, and yields the resulting
    domain event. Validation is a private phase — see the design
    rationale in {!Reserve_command_handler}. *)

(** {1 Validation errors} *)

type validation_error =
  | Non_positive_reservation_id of int
      (** The portfolio aggregate generates ids by an internal
        positive-counter, so a [reservation_id <= 0] cannot have
        come from a successful {!Reserve_command_workflow.execute}
        and is rejected at the parse boundary rather than handed
        on to {!Account.Portfolio.try_release}. *)

val validation_error_to_string : validation_error -> string

val release_error_to_string : Account.Portfolio.release_error -> string

(** {1 Validated form} *)

type validated_release_command = { reservation_id : int }

(** {1 Outcome} *)

type handle_error =
  | Validation of validation_error
  | Release of Account.Portfolio.release_error
      (** No [attempted] payload: there is no public
        Release-rejected integration event to populate, so the
        workflow has nothing to project on the failure track and
        the validated form does not need to be surfaced. *)

val handle :
  portfolio:Account.Portfolio.t ref ->
  Release_command.t ->
  (Account.Portfolio.Events.Reservation_released.t, handle_error) Rop.t
