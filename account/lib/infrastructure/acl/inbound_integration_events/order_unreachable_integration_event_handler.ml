module Order_unreachable = Order_unreachable_integration_event

let attach ~(events : Order_unreachable.t Bus.Event_bus.t)
    ~(dispatch_release : reservation_id:int -> unit) :
    Bus.Event_bus.subscription =
  Bus.Event_bus.subscribe events (fun ev ->
      dispatch_release ~reservation_id:ev.Order_unreachable.reservation_id)
