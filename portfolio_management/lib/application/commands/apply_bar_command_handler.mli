(** Command handler for {!Apply_bar_command.t}.

    Parses the wire-format bar, locates every registered
    pair-mean-reversion state whose pair includes the bar's
    instrument, and advances each one through
    {!Portfolio_management.Pair_mean_reversion.on_bar}. The
    state ref is mutated in place; emitted
    {!Construction_intent.t} values are returned in the Ok track
    for the workflow to feed into the unified construction →
    sizing → clipping pipeline.

    State-mutation semantics: refs are updated as the iteration
    progresses. A parse error before iteration short-circuits
    without touching any state. The handler does not validate
    intent consistency — that is the unified handler's job and
    happens in the workflow. *)

(** {1 Validation errors} *)

type validation_error =
  | Invalid_instrument of string
  | Invalid_decimal of { field : string; value : string }
  | Invalid_ts of string
  | Invalid_candle of string

val validation_error_to_string : validation_error -> string

type handle_error = Validation of validation_error

type ok = {
  intents : Portfolio_management.Common.Construction_intent.t list;
  mark : Core.Instrument.t * Decimal.t;
      (** The parsed [(instrument, close)] of the dispatched bar — the
          workflow uses it to refresh the per-book mark cache before
          handing emitted intents to the unified pipeline. *)
}

val handle :
  pair_mr_states_for:
    (Core.Instrument.t ->
    Portfolio_management.Pair_mean_reversion.state ref list) ->
  Apply_bar_command.t ->
  (ok, handle_error) Rop.t
(** Parse, advance every matching pair-mr state, collect emitted
    intents, and return the freshly-parsed mark for the bar's
    instrument. A validation error short-circuits the entire
    output, including the mark — a bar that fails to parse does
    not refresh the cache. *)
