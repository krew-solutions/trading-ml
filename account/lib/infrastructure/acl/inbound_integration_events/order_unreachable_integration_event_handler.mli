(** Handler for the inbound {!Order_unreachable_integration_event.t}
    (Account-side mirror of Broker's "transport failure" event).

    Subscribes to the supplied {!Bus.Event_bus.t}; on each incoming
    event extracts [reservation_id] and dispatches it through
    [~dispatch_release] — the function-port supplied by the
    composition root, typically a closure over Account's
    {!Bus.Command_bus.send} for {!Release_command}. The handler
    itself does not depend on the command type.

    {b Idempotent against duplicate / late events.} *)

module Order_unreachable = Order_unreachable_integration_event

val attach :
  events:Order_unreachable.t Bus.Event_bus.t ->
  dispatch_release:(reservation_id:int -> unit) ->
  Bus.Event_bus.subscription
