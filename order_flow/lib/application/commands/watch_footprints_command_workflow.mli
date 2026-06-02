(** Command pipeline for {!Watch_footprints_command.t}.

    Composes {!Watch_footprints_command_handler.handle} with one side
    effect — log on validation failure. Watch is fire-and-forget; there is
    no IE to publish, no audit log to persist, no saga correlation to
    record.

    The [Rop.t] return surfaces the validation error list to callers that
    want to act on it (the bus dispatcher today just discards it after the
    workflow's own [Log.warn] has already surfaced each error). *)

val execute :
  watch:
    (instrument:Core.Instrument.t ->
    boundary:Order_flow.Footprint.Values.Bar_boundary.t ->
    unit) ->
  Watch_footprints_command.t ->
  (unit, Watch_footprints_command_handler.handle_error) Rop.t
