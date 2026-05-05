module Order_unreachable = Order_unreachable_integration_event

let handle ~(dispatch_release : reservation_id:int -> unit) (ev : Order_unreachable.t) :
    unit =
  dispatch_release ~reservation_id:ev.Order_unreachable.reservation_id
