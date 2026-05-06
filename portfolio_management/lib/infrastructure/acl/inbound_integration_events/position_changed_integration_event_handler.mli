(** Handler for the inbound {!Position_changed_integration_event.t}.
    Bus-agnostic — translates the inbound DTO into a
    {!Portfolio_management_commands.Change_position_command.t} and
    dispatches via the supplied port. *)

module Position_changed = Position_changed_integration_event

val handle :
  dispatch_change_position:
    (Portfolio_management_commands.Change_position_command.t -> unit) ->
  Position_changed.t ->
  unit
