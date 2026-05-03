(** Handler for the inbound {!Cash_changed_integration_event.t}. *)

module Cash_changed = Cash_changed_integration_event

module Make (Bus : Bus.Event_bus.S) : sig
  val attach :
    events:Cash_changed.t Bus.t ->
    dispatch_change_cash:(Portfolio_management_commands.Change_cash_command.t -> unit) ->
    Bus.subscription
end
