(** Command handler for {!Apply_bar_command.t}.

    Parses the wire-format bar, locates every registered
    pair-mean-reversion state whose pair includes the bar's
    instrument, and advances each one through
    {!Portfolio_management.Pair_mean_reversion.on_bar}. The state ref
    is mutated in place; emitted target proposals are returned in the
    Ok track for the workflow to apply.

    State-mutation semantics: refs are updated as the iteration
    progresses. A parse error before iteration short-circuits without
    touching any state. The handler does not validate proposal
    consistency — that is {!Portfolio_management.Target_portfolio.apply_proposal}'s
    job and happens in the workflow. *)

(** {1 Validation errors} *)

type validation_error =
  | Invalid_instrument of string
  | Invalid_decimal of { field : string; value : string }
  | Invalid_ts of string
  | Invalid_candle of string

val validation_error_to_string : validation_error -> string

type handle_error = Validation of validation_error

val handle :
  pair_mr_states_for:
    (Core.Instrument.t -> Portfolio_management.Pair_mean_reversion.state ref list) ->
  Apply_bar_command.t ->
  (Portfolio_management.Common.Target_proposal.t list, handle_error) Rop.t
(** Parse, advance every matching pair-mr state, collect proposals.
    Returns the (possibly empty) list of emitted proposals on Ok, a
    validation error list on Error. *)
