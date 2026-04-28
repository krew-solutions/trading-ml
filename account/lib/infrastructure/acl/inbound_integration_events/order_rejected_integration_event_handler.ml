module Order_rejected = Order_rejected_integration_event

let attach ~(events : Order_rejected.t Bus.Event_bus.t)
    ~(dispatch_release : reservation_id:int -> unit) :
    Bus.Event_bus.subscription =
  Bus.Event_bus.subscribe events (fun ev ->
      dispatch_release ~reservation_id:ev.Order_rejected.reservation_id)
