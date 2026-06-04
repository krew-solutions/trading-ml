(** Translation for Finam [OrderState] (returned by PlaceOrder, GetOrder, and as
    the elements of GetOrders) into the broker BC's {!Broker_domain.Order.t}, and
    construction of the [Order] request message for PlaceOrder. Mirrors
    [Finam.Dto.Order] on the REST side, but over the typed protobuf shapes. *)

open Core
module Ord = Conv.Ord

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

let unknown_instrument = Conv.unknown_instrument

(** Decode an [OrderState]. The nested [order] carries the original request
    parameters (symbol, side, type, prices, tif, client_order_id); the
    top-level fields carry execution state (status, filled, transact time). *)
let of_pb (os : Ord.OrderState.t) : t =
  let order = os.order in
  let instrument =
    match order with
    | Some o -> ( try Instrument.of_qualified o.symbol with _ -> unknown_instrument)
    | None -> unknown_instrument
  in
  let side =
    match order with
    | Some o -> Conv.side_of_pb o.side
    | None -> Side.Buy
  in
  let kind =
    match order with
    | Some o ->
        Conv.kind_of_pb o.type' ~limit_price:o.limit_price ~stop_price:o.stop_price
    | None -> Market
  in
  let tif =
    match order with
    | Some o -> Conv.tif_of_pb o.time_in_force
    | None -> DAY
  in
  let client_order_id =
    match order with
    | Some o -> o.client_order_id
    | None -> ""
  in
  {
    client_order_id;
    order_id = os.order_id;
    exec_id = os.exec_id;
    instrument;
    side;
    quantity = Conv.decimal_of_pb os.initial_quantity;
    filled = Conv.decimal_of_pb os.executed_quantity;
    kind;
    tif;
    status = Conv.status_of_pb os.status;
    placed_ts = Conv.ts_of_pb os.transact_at;
  }

(** Build the [Order] request message for [PlaceOrder]. [account_id] travels in
    the message body (the REST path param is folded into the field on the wire).
    Limit/stop prices are attached only for the kinds that carry them. *)
let place_request
    ~account_id
    ~(instrument : Instrument.t)
    ~(side : Side.t)
    ~(quantity : Decimal.t)
    ~(kind : Broker_domain.Order.kind)
    ~(tif : Broker_domain.Order.time_in_force)
    ~client_order_id : Ord.Order.t =
  let limit_price, stop_price =
    match kind with
    | Market -> (None, None)
    | Limit p -> (Some (Conv.decimal_to_pb p), None)
    | Stop p -> (None, Some (Conv.decimal_to_pb p))
    | Stop_limit { stop; limit } ->
        (Some (Conv.decimal_to_pb limit), Some (Conv.decimal_to_pb stop))
  in
  Ord.Order.make ~account_id
    ~symbol:(Conv.symbol_of_instrument instrument)
    ~quantity:(Conv.decimal_to_pb quantity) ~side:(Conv.side_to_pb side)
    ~type':(Conv.kind_to_pb_type kind) ~time_in_force:(Conv.tif_to_pb tif) ?limit_price
    ?stop_price ~client_order_id ()
