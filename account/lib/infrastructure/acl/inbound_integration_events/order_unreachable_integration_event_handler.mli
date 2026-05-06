(** Handler for the inbound {!Order_unreachable_integration_event.t}.
    Bus-agnostic — translates the inbound DTO into a release dispatch
    via the supplied port. *)

module Order_unreachable = Order_unreachable_integration_event

val handle : dispatch_release:(reservation_id:int -> unit) -> Order_unreachable.t -> unit
