(** Command pipeline for {!Unwatch_bars_command.t}. Mirror of
    {!Watch_bars_command_workflow.execute} on the release side —
    validation errors are logged, the port call is fire-and-forget. *)

val execute :
  broker:Broker.client ->
  Unwatch_bars_command.t ->
  (unit, Unwatch_bars_command_handler.handle_error) Rop.t
