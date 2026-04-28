open Core

type t = {
  id : string;
  exec_id : string;
  client_order_id : string;
  instrument : Instrument_view_model.t;
  side : string;
  quantity : float;
  filled : float;
  remaining : float;
  kind : Order_kind_view_model.t;
  tif : string;
  status : string;
  created_ts : int64;
}
[@@deriving yojson]

type domain = Order.t

let of_domain (o : domain) : t =
  {
    id = o.id;
    exec_id = o.exec_id;
    client_order_id = o.client_order_id;
    instrument = Instrument_view_model.of_domain o.instrument;
    side = Side.to_string o.side;
    quantity = Decimal.to_float o.quantity;
    filled = Decimal.to_float o.filled;
    remaining = Decimal.to_float o.remaining;
    kind = Order_kind_view_model.of_domain o.kind;
    tif = Order.tif_to_string o.tif;
    status = Order.status_to_string o.status;
    created_ts = o.created_ts;
  }
