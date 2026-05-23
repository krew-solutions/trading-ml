(** Command handler for {!Unwatch_bars_command.t}.

    Mirror of {!Watch_bars_command_handler} on the release side:
    validate the wire primitives into [Core.Instrument.t] /
    [Core.Timeframe.t], then call {!Broker.unsubscribe} with
    [Subscribe_bars]. The adapter decrements its per-key
    refcount; the upstream venue feed only actually closes when
    no other caller still holds the key. *)

(** {1 Validation errors} *)

type validation_error = Invalid_symbol of string | Invalid_timeframe of string

val validation_error_to_string : validation_error -> string

(** {1 Validated form} *)

type validated_unwatch_bars_command = {
  instrument : Core.Instrument.t;
  timeframe : Core.Timeframe.t;
}

(** {1 Outcome} *)

type handle_error = Validation of validation_error

val handle : broker:Broker.client -> Unwatch_bars_command.t -> (unit, handle_error) Rop.t
