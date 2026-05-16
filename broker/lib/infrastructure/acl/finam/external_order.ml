type t = {
  client_order_id : string;
  order_id : string;
  exec_id : string;
  instrument : Core.Instrument.t;
  side : Core.Side.t;
  quantity : Decimal.t;
  filled : Decimal.t;
  kind : Order.kind;
  tif : Order.time_in_force;
  status : Order.status;
  placed_ts : int64;
}

let to_broker_domain ~placement_id (v : t) : Order.t =
  {
    placement_id;
    instrument = v.instrument;
    side = v.side;
    quantity = v.quantity;
    filled = v.filled;
    kind = v.kind;
    tif = v.tif;
    status = v.status;
    placed_ts = v.placed_ts;
  }
