(** Handler for the inbound {!Order_rejected_integration_event.t}.
    Functor over {!Bus.Event_bus.S} — composition root applies it
    with whichever concrete bus implementation is in use
    (in-memory today, Kafka tomorrow). The handler itself is
    transport-agnostic. *)

module Order_rejected = Order_rejected_integration_event

module Make (Bus : Bus.Event_bus.S) : sig
  val attach :
    events:Order_rejected.t Bus.t ->
    dispatch_release:(reservation_id:int -> unit) ->
    Bus.subscription
end
