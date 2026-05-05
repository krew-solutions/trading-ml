(** Handler for the inbound {!Cash_changed_integration_event.t}.
    Bus-agnostic — translates the inbound DTO into a
    {!Portfolio_management_commands.Change_cash_command.t} and
    dispatches via the supplied port. *)

module Cash_changed = Cash_changed_integration_event

val handle :
  dispatch_change_cash:(Portfolio_management_commands.Change_cash_command.t -> unit) ->
  Cash_changed.t ->
  unit
