(** Command handler for {!Define_pair_kalman_mr_command.t}.

    Validates the wire shape into a {!Kalman_dlm_config.t}, builds
    the initial {!Kalman_dlm_state.t}, and hands the result to the
    [persist_pair_kalman_mr_state] closure for storage in the
    per-book Kalman pair-mr registry. *)

type validation_error =
  | Invalid_book_id of string
  | Invalid_instrument of { field : string; value : string }
  | Invalid_pair of string
  | Invalid_decimal of { field : string; value : string }
  | Invalid_z_score of { field : string; value : string }
  | Invalid_discount of string
  | Invalid_v_observation_noise of string
  | Invalid_burn_in of int
  | Invalid_prior_variance of string
  | Invalid_prior_beta of string
  | Invalid_kalman_config of string

val validation_error_to_string : validation_error -> string

type handle_error = Validation of validation_error

val handle_error_to_string : handle_error -> string

val handle :
  persist_pair_kalman_mr_state:
    (book_id:Portfolio_management.Common.Book_id.t ->
    pair:Portfolio_management.Common.Pair.t ->
    state:Portfolio_management.Pair_kalman_mean_reversion.state ->
    unit) ->
  Define_pair_kalman_mr_command.t ->
  (unit, handle_error) Rop.t
(** Validate, build config, initialise state, persist. All
    validation errors aggregate via Rop's applicative. *)
