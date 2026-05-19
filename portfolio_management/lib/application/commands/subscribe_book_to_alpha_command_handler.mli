(** Command handler for {!Subscribe_book_to_alpha_command.t}.

    Validates the wire fields and registers a
    {!Portfolio_management.Common.Alpha_subscription.t} via the
    supplied [persist] closure. The closure is responsible for
    enforcing idempotence on the triplet — typically by checking
    membership before appending. *)

type validation_error =
  | Invalid_alpha_source_id of string
  | Invalid_instrument of string
  | Invalid_book_id of string

val validation_error_to_string : validation_error -> string

type handle_error = Validation of validation_error

val handle_error_to_string : handle_error -> string

val handle :
  persist_subscription:
    (Portfolio_management.Common.Alpha_subscription.t -> unit) ->
  Subscribe_book_to_alpha_command.t ->
  (unit, handle_error) Rop.t
(** Validate the wire fields and hand a built
    {!Alpha_subscription.t} to [persist_subscription]. All
    validation errors are aggregated via Rop's applicative so
    the caller can report every problem at once. *)
