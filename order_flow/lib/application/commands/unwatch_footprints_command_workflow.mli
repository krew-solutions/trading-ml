(** Command pipeline for {!Unwatch_footprints_command.t}.

    Mirror of {!Watch_footprints_command_workflow}: compose the handler
    with one side effect — log on validation failure. Fire-and-forget; no
    IE, no audit log, no saga correlation. The [Rop.t] return surfaces the
    validation error list to callers that want to act on it. *)

val execute :
  unwatch:
    (instrument:Core.Instrument.t ->
    boundary:Order_flow.Footprint.Values.Bar_boundary.t ->
    unit) ->
  Unwatch_footprints_command.t ->
  (unit, Unwatch_footprints_command_handler.handle_error) Rop.t
