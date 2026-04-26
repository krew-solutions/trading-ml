open Core

type place_order_port =
  instrument:Instrument.t ->
  side:Side.t ->
  quantity:Decimal.t ->
  kind:Order.kind ->
  tif:Order.time_in_force ->
  client_order_id:string ->
  Order.t

type order_forwarded = {
  client_order_id : string;
  reservation_id : int;
  broker_order : Order.t;
}

type forward_rejection =
  | Order_rejected_by_broker of {
      client_order_id : string;
      reservation_id : int;
      reason : string;
    }
  | Broker_unreachable of {
      client_order_id : string;
      reservation_id : int;
      reason : string;
    }

let forward_rejection_to_string = function
  | Order_rejected_by_broker { reason; _ } -> Printf.sprintf "broker rejected: %s" reason
  | Broker_unreachable { reason; _ } -> Printf.sprintf "broker unreachable: %s" reason

let reservation_id_of_rejection = function
  | Order_rejected_by_broker { reservation_id; _ } -> reservation_id
  | Broker_unreachable { reservation_id; _ } -> reservation_id

let handle
    ~(place_order : place_order_port)
    ~(kind : Order.kind)
    ~(tif : Order.time_in_force)
    ~(client_order_id : string)
    (ev : Engine.Portfolio.amount_reserved) : (order_forwarded, forward_rejection) Rop.t =
  try
    let broker_order =
      place_order ~instrument:ev.instrument ~side:ev.side ~quantity:ev.quantity ~kind ~tif
        ~client_order_id
    in
    match broker_order.status with
    | Rejected ->
        Rop.fail
          (Order_rejected_by_broker
             {
               client_order_id;
               reservation_id = ev.reservation_id;
               reason = Order.status_to_string broker_order.status;
             })
    | _ ->
        Rop.succeed { client_order_id; reservation_id = ev.reservation_id; broker_order }
  with e ->
    Rop.fail
      (Broker_unreachable
         {
           client_order_id;
           reservation_id = ev.reservation_id;
           reason = Printexc.to_string e;
         })
