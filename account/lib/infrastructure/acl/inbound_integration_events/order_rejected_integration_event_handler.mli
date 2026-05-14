(** Handler for the inbound {!Order_rejected_integration_event.t}.

    Translates the broker-side rejection event into a local
    {!Account_commands.Release_command.t} and dispatches via the
    supplied port. The [reason] field is dropped — release is
    unconditional once a rejection has been observed. *)

module Order_rejected = Order_rejected_integration_event

val handle :
  dispatch_release:(Account_commands.Release_command.t -> unit) ->
  Order_rejected.t ->
  unit
