(** Handler for the inbound {!Position_changed_integration_event.t}.
    Translates the DTO into a {!Record_position_command.t} and
    dispatches via the supplied port. *)

module Position_changed = Position_changed_integration_event

val handle :
  dispatch_record_position:(Pre_trade_risk_commands.Record_position_command.t -> unit) ->
  Position_changed.t ->
  unit
