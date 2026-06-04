(** Value-object translation between the generated Finam protobuf types and our
    domain vocabulary. This is the only place the wire shapes meet the model, so
    a contract change touches one file (mirrors the role of [Finam.Dto.Wire] on
    the REST side).

    Conventions of the generated code ([ocaml-protoc-plugin]):
    - [google.type.Decimal] collapses to a bare [string] ([""] when unset);
    - message-typed fields (Decimal, Timestamp) are [_ option];
    - enum fields are bare, defaulting to their [*_UNSPECIFIED] constructor. *)

open Core

(* Short aliases for the deep generated module paths. *)
module Pb_decimal = Finam_grpc_proto.Decimal.Google.Type.Decimal
module Pb_ts = Finam_grpc_proto.Timestamp.Google.Protobuf.Timestamp
module Pb_side = Finam_grpc_proto.Side.Grpc.Tradeapi.V1.Side
module Pb_interval = Finam_grpc_proto.Interval.Google.Type.Interval
module Md = Finam_grpc_proto.Marketdata_service.Grpc.Tradeapi.V1.Marketdata
module Ord = Finam_grpc_proto.Orders_service.Grpc.Tradeapi.V1.Orders
module Pb_account_trade = Finam_grpc_proto.Trade.Grpc.Tradeapi.V1.AccountTrade

(* ---- scalars ----------------------------------------------------------- *)

(** Encode a domain decimal as the proto [google.type.Decimal] string. *)
let decimal_to_pb (d : Decimal.t) : Pb_decimal.t = Decimal.to_string d

(** Decode an optional proto decimal; absent / empty ⇒ [Decimal.zero], matching
    the REST decoder's tolerance. *)
let decimal_of_pb (d : Pb_decimal.t option) : Decimal.t =
  match d with
  | Some s when s <> "" -> ( try Decimal.of_string s with _ -> Decimal.zero)
  | _ -> Decimal.zero

(** Proto [Timestamp] ⇒ unix-epoch seconds. We keep seconds only (our domain
    timestamps are second-resolution); sub-second [nanos] is dropped. *)
let ts_of_pb (t : Pb_ts.t option) : int64 =
  match t with
  | Some { seconds; _ } -> Int64.of_int seconds
  | None -> 0L

(** Unix-epoch seconds ⇒ proto [Timestamp]. *)
let ts_to_pb (ts : int64) : Pb_ts.t = Pb_ts.make ~seconds:(Int64.to_int ts) ~nanos:0 ()

(** Build a proto [Interval] from an inclusive [from]/[to] epoch-seconds
    window. Used by the bars and account-trades history queries. *)
let interval ~from_ts ~to_ts : Pb_interval.t =
  Pb_interval.make ~start_time:(ts_to_pb from_ts) ~end_time:(ts_to_pb to_ts) ()

(* ---- side -------------------------------------------------------------- *)

let side_to_pb : Side.t -> Pb_side.t = function
  | Buy -> SIDE_BUY
  | Sell -> SIDE_SELL

(** Aggressor side. [SIDE_UNSPECIFIED] ⇒ [None] (auction crosses / negotiated
    trades with no initiator), per ADR 0032 on the public tape. *)
let side_of_pb_opt : Pb_side.t -> Side.t option = function
  | SIDE_BUY -> Some Side.Buy
  | SIDE_SELL -> Some Side.Sell
  | SIDE_UNSPECIFIED -> None

(** Own-fill side: a fill always has a definite side; default [Buy] on the
    impossible [UNSPECIFIED], matching the REST decoder. *)
let side_of_pb : Pb_side.t -> Side.t = function
  | SIDE_SELL -> Side.Sell
  | SIDE_BUY | SIDE_UNSPECIFIED -> Side.Buy

(* ---- timeframe --------------------------------------------------------- *)

(** Domain timeframe ⇒ Finam [TimeFrame] enum. Finam's enum carries finer
    granularities (H2/H8/QR) our model does not expose; the reverse map below
    folds those onto the nearest domain value it recognises. *)
let timeframe_to_pb : Timeframe.t -> Md.TimeFrame.t = function
  | M1 -> TIME_FRAME_M1
  | M5 -> TIME_FRAME_M5
  | M15 -> TIME_FRAME_M15
  | M30 -> TIME_FRAME_M30
  | H1 -> TIME_FRAME_H1
  | H4 -> TIME_FRAME_H4
  | D1 -> TIME_FRAME_D
  | W1 -> TIME_FRAME_W
  | MN1 -> TIME_FRAME_MN

(* ---- order kind / tif / status ---------------------------------------- *)

let kind_to_pb_type : Broker_domain.Order.kind -> Ord.OrderType.t = function
  | Market -> ORDER_TYPE_MARKET
  | Limit _ -> ORDER_TYPE_LIMIT
  | Stop _ -> ORDER_TYPE_STOP
  | Stop_limit _ -> ORDER_TYPE_STOP_LIMIT

(** Reconstruct the domain order kind from the wire [type] enum plus the
    price fields carried on the (nested) [Order] message. *)
let kind_of_pb (ty : Ord.OrderType.t) ~limit_price ~stop_price : Broker_domain.Order.kind
    =
  match ty with
  | ORDER_TYPE_LIMIT -> Limit (decimal_of_pb limit_price)
  | ORDER_TYPE_STOP -> Stop (decimal_of_pb stop_price)
  | ORDER_TYPE_STOP_LIMIT ->
      Stop_limit { stop = decimal_of_pb stop_price; limit = decimal_of_pb limit_price }
  | ORDER_TYPE_MARKET | ORDER_TYPE_UNSPECIFIED | ORDER_TYPE_MULTI_LEG -> Market

let tif_to_pb : Broker_domain.Order.time_in_force -> Ord.TimeInForce.t = function
  | DAY -> TIME_IN_FORCE_DAY
  | GTC -> TIME_IN_FORCE_GOOD_TILL_CANCEL
  | IOC -> TIME_IN_FORCE_IOC
  | FOK -> TIME_IN_FORCE_FOK

let tif_of_pb : Ord.TimeInForce.t -> Broker_domain.Order.time_in_force = function
  | TIME_IN_FORCE_GOOD_TILL_CANCEL | TIME_IN_FORCE_GOOD_TILL_CROSSING -> GTC
  | TIME_IN_FORCE_IOC -> IOC
  | TIME_IN_FORCE_FOK -> FOK
  | TIME_IN_FORCE_DAY
  | TIME_IN_FORCE_UNSPECIFIED
  | TIME_IN_FORCE_EXT
  | TIME_IN_FORCE_ON_OPEN
  | TIME_IN_FORCE_ON_CLOSE -> DAY

(** Finam [OrderStatus] ⇒ domain status. Mirrors [Finam.Dto.Wire]: the many
    SL/TP and lifecycle sub-states Finam exposes collapse onto the domain's
    coarse lifecycle, with anything unrecognised treated as [New]. *)
let status_of_pb : Ord.OrderStatus.t -> Broker_domain.Order.status = function
  | ORDER_STATUS_NEW -> New
  | ORDER_STATUS_PARTIALLY_FILLED -> Partially_filled
  | ORDER_STATUS_FILLED | ORDER_STATUS_EXECUTED -> Filled
  | ORDER_STATUS_CANCELED -> Cancelled
  | ORDER_STATUS_REJECTED
  | ORDER_STATUS_REJECTED_BY_EXCHANGE
  | ORDER_STATUS_DENIED_BY_BROKER -> Rejected
  | ORDER_STATUS_EXPIRED -> Expired
  | ORDER_STATUS_PENDING_CANCEL -> Pending_cancel
  | ORDER_STATUS_PENDING_NEW -> Pending_new
  | ORDER_STATUS_SUSPENDED -> Suspended
  | ORDER_STATUS_FAILED -> Failed
  | _ -> New

(* ---- instrument symbol ------------------------------------------------- *)

(** Finam addresses instruments as [TICKER@MIC]. Identical to the REST routing
    helper; duplicated here to keep this adapter self-contained. *)
let symbol_of_instrument (i : Instrument.t) : string =
  Ticker.to_string (Instrument.ticker i) ^ "@" ^ Mic.to_string (Instrument.venue i)

(** Placeholder for a wire symbol we cannot parse — keeps a malformed frame from
    aborting a whole decode, matching the REST decoder's defensiveness. *)
let unknown_instrument =
  Instrument.make ~ticker:(Ticker.of_string "UNKNOWN") ~venue:(Mic.of_string "XXXX") ()

(* ---- market-data / trade event lifting -------------------------------- *)

let candle_of_bar (b : Md.Bar.t) : Candle.t =
  Candle.make ~ts:(ts_of_pb b.timestamp) ~open_:(decimal_of_pb b.open')
    ~high:(decimal_of_pb b.high) ~low:(decimal_of_pb b.low) ~close:(decimal_of_pb b.close)
    ~volume:(decimal_of_pb b.volume)

(** A public-tape print (no order linkage). [side] is the venue aggressor or
    [None] for auction/negotiated trades (ADR 0032). *)
let public_trade_of_md ~(instrument : Instrument.t) (tr : Md.Trade.t) :
    Broker_domain.Remote_broker.Events.Public_trade_printed.t =
  {
    instrument;
    side = side_of_pb_opt tr.side;
    quantity = decimal_of_pb tr.size;
    price = decimal_of_pb tr.price;
    ts = ts_of_pb tr.timestamp;
  }

(** An own-account fill, given the saga [placement_id] the broker resolved for
    its parent order. Fee is not carried on Finam's [AccountTrade] (the
    [accrued_interest] field is NKD, not commission), so it is [zero], matching
    the REST sibling. *)
let trade_executed_of_account ~placement_id (at : Pb_account_trade.t) :
    Broker_domain.Remote_broker.Events.Trade_executed.t =
  {
    placement_id;
    trade_id = at.trade_id;
    instrument = (try Instrument.of_qualified at.symbol with _ -> unknown_instrument);
    side = side_of_pb at.side;
    quantity = decimal_of_pb at.size;
    price = decimal_of_pb at.price;
    fee = Decimal.zero;
    ts = ts_of_pb at.timestamp;
  }

(** Per-order trade detail (for [get_trades]); fee [zero] as above. *)
let order_trade_of_account (at : Pb_account_trade.t) : Broker_domain.Order.Trade.t =
  {
    trade_id = at.trade_id;
    ts = ts_of_pb at.timestamp;
    quantity = decimal_of_pb at.size;
    price = decimal_of_pb at.price;
    fee = Decimal.zero;
  }
