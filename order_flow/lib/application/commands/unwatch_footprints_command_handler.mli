(** Command handler for {!Unwatch_footprints_command.t}.

    Mirror of {!Watch_footprints_command_handler}: validate the wire
    primitives into domain values, then on success call the injected
    [unwatch] port with the parsed instrument and boundary. The BC-side
    refcount stops aggregating the boundary only on the 1->0 transition.
    Side-effect-only on success; validation failures are returned for the
    workflow to log. *)

(** {1 Validation errors} *)

type validation_error = Invalid_symbol of string | Invalid_boundary of string

val validation_error_to_string : validation_error -> string

(** {1 Validated form} *)

type validated_unwatch_footprints_command = {
  instrument : Core.Instrument.t;
  boundary : Order_flow.Footprint.Values.Bar_boundary.t;
}

(** {1 Outcome} *)

type handle_error = Validation of validation_error

val handle :
  unwatch:
    (instrument:Core.Instrument.t ->
    boundary:Order_flow.Footprint.Values.Bar_boundary.t ->
    unit) ->
  Unwatch_footprints_command.t ->
  (unit, handle_error) Rop.t
