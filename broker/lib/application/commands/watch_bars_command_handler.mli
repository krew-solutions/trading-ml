(** Command handler for {!Watch_bars_command.t}.

    Two phases in one Rop pipeline:

    - {b Validate}: parse the wire-format primitives back into
      domain values ([Core.Instrument.t], [Core.Timeframe.t]) via
      parallel applicative branches. Multiple bad fields surface
      as a non-empty error list in one pass.
    - {b Watch}: on validation success, call
      {!Broker.subscribe} with [Subscribe_bars] on the injected
      port. The adapter-side refcount merges this caller with any
      other watcher on the same key; the upstream venue feed
      opens only on the 0→1 transition.

    Side-effect-only on success: no IE published, no audit entry.
    Failures are returned to the enclosing
    {!Watch_bars_command_workflow.execute} so it can log them —
    the caller has no callback mechanism. *)

(** {1 Validation errors} *)

type validation_error = Invalid_symbol of string | Invalid_timeframe of string

val validation_error_to_string : validation_error -> string

(** {1 Validated form} *)

type validated_watch_bars_command = {
  instrument : Core.Instrument.t;
  timeframe : Core.Timeframe.t;
}
(** Post-parse intermediate form: wire primitives lifted into
    domain values. *)

(** {1 Outcome} *)

type handle_error = Validation of validation_error

val handle : broker:Broker.client -> Watch_bars_command.t -> (unit, handle_error) Rop.t
(** Validate the command and, on success, forward the interest
    via [Broker.subscribe]. Returns an accumulated list of
    validation errors on parse failure; the port call itself is
    void. *)
