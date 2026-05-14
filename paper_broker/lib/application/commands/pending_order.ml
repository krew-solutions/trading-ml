type t = { order : Paper_broker.Order.t; reservation_id : int; correlation_id : string }

let make
    ~(order : Paper_broker.Order.t)
    ~(reservation_id : int)
    ~(correlation_id : string) : t =
  { order; reservation_id; correlation_id }

let id (t : t) : string = t.order.id

let instrument (t : t) : Core.Instrument.t = t.order.instrument

let is_terminal (t : t) : bool = Paper_broker.Order.is_terminal t.order

let with_order (t : t) (order : Paper_broker.Order.t) : t = { t with order }
