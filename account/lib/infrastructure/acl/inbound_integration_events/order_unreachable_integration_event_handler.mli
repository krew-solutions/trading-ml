(** Handler for the inbound {!Order_unreachable_integration_event.t}.
    Functor over {!Bus.Event_bus.S} — transport-agnostic. *)

module Order_unreachable = Order_unreachable_integration_event

module Make (Bus : Bus.Event_bus.S) : sig
  val attach :
    events:Order_unreachable.t Bus.t ->
    dispatch_release:(reservation_id:int -> unit) ->
    Bus.subscription
end
