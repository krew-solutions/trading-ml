(** Handler for the inbound {!Cash_changed_integration_event.t}. *)

module Cash_changed = Cash_changed_integration_event

module Make (Bus : Bus.Event_bus.S) : sig
  val attach :
    events:Cash_changed.t Bus.t ->
    dispatch_project_cash_changed:
      (Portfolio_management_commands.Project_cash_changed_command.t -> unit) ->
    Bus.subscription
end
