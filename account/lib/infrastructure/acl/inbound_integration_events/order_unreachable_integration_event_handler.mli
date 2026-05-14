(** Handler for the inbound {!Order_unreachable_integration_event.t}.

    Translates the broker-side unreachable event into a local
    {!Account_commands.Release_command.t} and dispatches via the
    supplied port. *)

module Order_unreachable = Order_unreachable_integration_event

val handle :
  dispatch_release:(Account_commands.Release_command.t -> unit) ->
  Order_unreachable.t ->
  unit
