module Order_unreachable = Order_unreachable_integration_event

module Make (Bus : Bus.Event_bus.S) = struct
  let attach
      ~(events : Order_unreachable.t Bus.t)
      ~(dispatch_release : reservation_id:int -> unit) : Bus.subscription =
    Bus.subscribe events (fun ev ->
        dispatch_release ~reservation_id:ev.Order_unreachable.reservation_id)
end
