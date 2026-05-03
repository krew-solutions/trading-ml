(** Handler for the inbound {!Position_changed_integration_event.t}.

    Functor over {!Bus.Event_bus.S} — composition root applies it
    with whichever concrete bus implementation is in use. The handler
    translates the inbound IE into a
    {!Change_position_command.t} and dispatches it. *)

module Position_changed = Position_changed_integration_event

module Make (Bus : Bus.Event_bus.S) : sig
  val attach :
    events:Position_changed.t Bus.t ->
    dispatch_change_position:
      (Portfolio_management_commands.Change_position_command.t -> unit) ->
    Bus.subscription
end
