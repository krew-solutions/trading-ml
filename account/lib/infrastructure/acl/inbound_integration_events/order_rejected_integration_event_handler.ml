module Order_rejected = Order_rejected_integration_event

let handle ~(dispatch_release : reservation_id:int -> unit) (ev : Order_rejected.t) : unit
    =
  dispatch_release ~reservation_id:ev.Order_rejected.reservation_id
