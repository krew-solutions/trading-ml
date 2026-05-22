open Core

type t = {
  client_order_id : string;
  order_id : string;
  exec_id : string;
  instrument : Instrument.t;
  side : Side.t;
  quantity : Decimal.t;
  filled : Decimal.t;
  kind : Broker_domain.Order.kind;
  tif : Broker_domain.Order.time_in_force;
  status : Broker_domain.Order.status;
  placed_ts : int64;
}

let to_domain ~placement_id (v : t) : Broker_domain.Order.t =
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

(** Build the JSON body for [POST /v1/accounts/{id}/orders].
    Prices and quantities use the [{"value": "..."}] wrapper Finam
    requires on the wire (protobuf [google.type.Decimal]). *)
let place_order_payload
    ~(instrument : Instrument.t)
    ~(side : Side.t)
    ~(quantity : Decimal.t)
    ~(kind : Broker_domain.Order.kind)
    ~(tif : Broker_domain.Order.time_in_force)
    ?client_order_id
    () : Yojson.Safe.t =
  let w = Acl_common.Decimal_wire.yojson_of_t_wrapped in
  let price_fields =
    match kind with
    | Market -> []
    | Limit p -> [ ("limit_price", w p) ]
    | Stop p -> [ ("stop_price", w p) ]
    | Stop_limit { stop; limit } -> [ ("limit_price", w limit); ("stop_price", w stop) ]
  in
  let coid =
    match client_order_id with
    | None -> []
    | Some id -> [ ("client_order_id", `String id) ]
  in
  `Assoc
    ([
       ("symbol", `String (Routing.qualify_instrument instrument));
       ("quantity", w quantity);
       ("side", `String (Wire.finam_side_to_wire side));
       ("type", `String (Wire.finam_kind_to_wire kind));
       ("time_in_force", `String (Wire.finam_tif_to_wire tif));
     ]
    @ price_fields @ coid)

(** Decode a single Finam [OrderState] JSON (returned by GetOrder,
    PlaceOrder, and as array elements in GetOrders). The nested
    [order] object carries the original request parameters;
    top-level fields carry execution state. *)
let of_json (j : Yojson.Safe.t) : t =
  let open Yojson.Safe.Util in
  let str k =
    match member k j with
    | `String s -> s
    | _ -> ""
  in
  let inner = member "order" j in
  let inner_str k =
    match member k inner with
    | `String s -> s
    | _ -> ""
  in
  let dec k obj = try Wire.decimal_of_json (member k obj) with _ -> Decimal.zero in
  let instrument =
    try Instrument.of_qualified (inner_str "symbol")
    with _ ->
      Instrument.make ~ticker:(Ticker.of_string "UNKNOWN") ~venue:(Mic.of_string "XXXX")
        ()
  in
  let price_fn field_name = dec field_name inner in
  let kind = Wire.finam_kind_of_wire (inner_str "type") price_fn in
  let tif = Wire.finam_tif_of_wire (inner_str "time_in_force") in
  let side = Wire.finam_side_of_wire (inner_str "side") in
  let status = Wire.finam_status_of_wire (str "status") in
  let placed_ts =
    match member "transact_at" j with
    | `String s -> Datetime.Iso8601.parse s
    | _ -> 0L
  in
  {
    client_order_id = inner_str "client_order_id";
    order_id = str "order_id";
    exec_id = str "exec_id";
    instrument;
    side;
    quantity = dec "initial_quantity" j;
    filled = dec "executed_quantity" j;
    kind;
    tif;
    status;
    placed_ts;
  }

let list_of_json (j : Yojson.Safe.t) : t list =
  let open Yojson.Safe.Util in
  match member "orders" j with
  | `List items -> List.map of_json items
  | _ -> []
