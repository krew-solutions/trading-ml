(** Handler for the inbound {!Order_rejected_integration_event.t}.
    Bus-agnostic — translates the inbound DTO into a release dispatch
    via the supplied port. The composition root subscribes this
    function to whatever bus consumer is appropriate. *)

module Order_rejected = Order_rejected_integration_event

val handle : dispatch_release:(reservation_id:int -> unit) -> Order_rejected.t -> unit
