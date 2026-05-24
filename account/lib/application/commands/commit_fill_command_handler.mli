(** Command handler for {!Commit_fill_command.t}.

    Parses the wire payload, invokes
    {!Account.Portfolio.commit_fill}, and yields the resulting
    {!Account.Portfolio.commit_fill_outcome} — either a
    partial-draw {!Reservation_drawn_down} or a terminal
    {!Reservation_filled} event. The event is built inside the
    aggregate operation; the handler simply unpacks the
    [Ok (_, outcome)] branch and forwards the variant to the
    workflow, which fans out to the matching publisher.

    Symmetric with {!Release_command_handler}: validation errors
    sit on one side of [handle_error], the aggregate's typed
    [commit_fill_error] ([Reservation_not_found] |
    [Overfill]) on the other. The workflow propagates both Error
    tracks; the application layer (factory) decides what to do
    with them (silent drop, log, alert).

    Validation is intentionally a private internal phase — same
    rationale as {!Reserve_command_handler}: a CQRS command has
    exactly one workflow, no further pipeline stage to compose
    with after parsing. *)

(** {1 Validation errors} *)

type validation_error =
  | Non_positive_reservation_id of int
  | Invalid_quantity_format of string
  | Non_positive_quantity of string
  | Invalid_price_format of string
  | Non_positive_price of string
  | Invalid_fee_format of string
  | Negative_fee of string

val validation_error_to_string : validation_error -> string

val commit_fill_error_to_string : Account.Portfolio.commit_fill_error -> string

(** {1 Validated form} *)

type validated_commit_fill_command = {
  reservation_id : int;
  quantity : Decimal.t;
  price : Decimal.t;
  fee : Decimal.t;
}

(** {1 Outcome} *)

type handle_error =
  | Validation of validation_error
  | Commit of Account.Portfolio.commit_fill_error

val handle :
  portfolio:Account.Portfolio.t ref ->
  Commit_fill_command.t ->
  (Account.Portfolio.commit_fill_outcome, handle_error) Rop.t
