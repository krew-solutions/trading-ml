(** Handler for the inbound {!Order_rejected_integration_event.t}
    (Account-side mirror of Broker's "broker said no" event).

    Subscribes to the supplied {!Bus.Event_bus.t}; on each incoming
    event extracts [reservation_id] and dispatches it through
    [~dispatch_release] — the function-port supplied by the
    composition root, typically a closure over Account's
    {!Bus.Command_bus.send} for {!Release_command}. The handler
    itself does not depend on the command type, keeping this
    inbound-ACL library free of cycles back into commands.

    {b Idempotent against duplicate / late events.} The Release
    pipeline downstream silently no-ops when the reservation is
    absent. *)

module Order_rejected = Order_rejected_integration_event

val attach :
  events:Order_rejected.t Bus.Event_bus.t ->
  dispatch_release:(reservation_id:int -> unit) ->
  Bus.Event_bus.subscription
