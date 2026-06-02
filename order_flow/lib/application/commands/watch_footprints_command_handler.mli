(** Command handler for {!Watch_footprints_command.t}.

    Two phases in one Rop pipeline:

    - {b Validate}: parse the wire-format primitives back into domain
      values ([Core.Instrument.t],
      [Order_flow.Footprint.Values.Bar_boundary.t]) via parallel
      applicative branches. Multiple bad fields surface as a non-empty
      error list in one pass.
    - {b Watch}: on validation success, call the injected [watch] port
      with the parsed instrument and boundary. The BC-side refcount merges
      this caller with any other watcher on the same key; the boundary
      starts being aggregated only on the 0->1 transition.

    Side-effect-only on success: no IE published, no audit entry. Failures
    are returned to the enclosing {!Watch_footprints_command_workflow.execute}
    so it can log them — the caller has no callback mechanism. *)

(** {1 Validation errors} *)

type validation_error = Invalid_symbol of string | Invalid_boundary of string

val validation_error_to_string : validation_error -> string

(** {1 Validated form} *)

type validated_watch_footprints_command = {
  instrument : Core.Instrument.t;
  boundary : Order_flow.Footprint.Values.Bar_boundary.t;
}
(** Post-parse intermediate form: wire primitives lifted into domain
    values. *)

(** {1 Outcome} *)

type handle_error = Validation of validation_error

val handle :
  watch:
    (instrument:Core.Instrument.t ->
    boundary:Order_flow.Footprint.Values.Bar_boundary.t ->
    unit) ->
  Watch_footprints_command.t ->
  (unit, handle_error) Rop.t
(** Validate the command and, on success, forward the interest via the
    [watch] port. Returns an accumulated list of validation errors on
    parse failure; the port call itself is void. *)
