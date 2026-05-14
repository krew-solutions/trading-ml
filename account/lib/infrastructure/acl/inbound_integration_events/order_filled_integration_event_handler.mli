(** Handler for the inbound {!Order_filled_integration_event.t}.

    Translates each broker-side fill event into a local
    {!Account_commands.Commit_fill_command.t} and dispatches via
    the supplied port. *)

module Order_filled = Order_filled_integration_event

val handle :
  dispatch_commit_fill:(Account_commands.Commit_fill_command.t -> unit) ->
  Order_filled.t ->
  unit
