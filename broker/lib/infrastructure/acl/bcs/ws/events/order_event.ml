open Core

type t = {
  original_client_order_id : string;
  client_order_id : string;
  message_type : string;
  order_status : string;
  execution_type : string;
  order_quantity : Decimal.t;
  executed_quantity : Decimal.t;
  last_quantity : Decimal.t;
  remained_quantity : Decimal.t;
  ticker : string;
  class_code : string;
  side : Side.t;
  order_type : string;
  average_price : Decimal.t;
  order_id : string;
  execution_id : string;
  price : Decimal.t;
  currency : string;
  client_code : string;
  transaction_time : int64;
  trade_date : string;
  order_number : string;
  accrued_coupon : Decimal.t;
  execution_value : Decimal.t;
  commission : Decimal.t;
  security_exchange : string;
  reject_reason : string option;
}

let string_field k j : string =
  let open Yojson.Safe.Util in
  match member k j with
  | `String s -> s
  | _ -> ""

let decimal_field k j : Decimal.t =
  let open Yojson.Safe.Util in
  match member k j with
  | `Float f -> Decimal.of_float f
  | `Int n -> Decimal.of_int n
  | `Intlit s -> Decimal.of_string s
  | `String s when s <> "" -> Decimal.of_string s
  | _ -> Decimal.zero

let parse_side : Yojson.Safe.t -> Side.t = function
  | `String "1" | `Int 1 -> Side.Buy
  | `String "2" | `Int 2 -> Side.Sell
  | _ -> raise Exit

let parse (j : Yojson.Safe.t) : t option =
  let open Yojson.Safe.Util in
  try
    let data = member "data" j in
    let original_client_order_id = string_field "originalClientOrderId" j in
    let client_order_id = string_field "clientOrderId" j in
    let transaction_time =
      match member "transactionTime" data with
      | `String s -> Datetime.Iso8601.parse s
      | `Int n -> Int64.of_int n
      | _ -> 0L
    in
    let reject_reason =
      match member "rejectReason" data with
      | `String s when s <> "" -> Some s
      | _ -> None
    in
    Some
      {
        original_client_order_id;
        client_order_id;
        message_type = string_field "messageType" data;
        order_status = string_field "orderStatus" data;
        execution_type = string_field "executionType" data;
        order_quantity = decimal_field "orderQuantity" data;
        executed_quantity = decimal_field "executedQuantity" data;
        last_quantity = decimal_field "lastQuantity" data;
        remained_quantity = decimal_field "remainedQuantity" data;
        ticker = string_field "ticker" data;
        class_code = string_field "classCode" data;
        side = parse_side (member "side" data);
        order_type = string_field "orderType" data;
        average_price = decimal_field "averagePrice" data;
        order_id = string_field "orderId" data;
        execution_id = string_field "executionId" data;
        price = decimal_field "price" data;
        currency = string_field "currency" data;
        client_code = string_field "clientCode" data;
        transaction_time;
        trade_date = string_field "tradeDate" data;
        order_number = string_field "orderNumber" data;
        accrued_coupon = decimal_field "accruedCoupon" data;
        execution_value = decimal_field "executionValue" data;
        commission = decimal_field "commission" data;
        security_exchange = string_field "securityExchange" data;
        reject_reason;
      }
  with _ -> None

let is_fill (t : t) : bool = t.execution_type = "11"

let to_domain ~(placement_id : int) (t : t) :
    Broker_domain.Remote_broker.Events.Trade_executed.t option =
  if not (is_fill t) then None
  else
    let instrument =
      Instrument.make ~ticker:(Ticker.of_string t.ticker) ~venue:(Mic.of_string "MISX")
        ~board:(Board.of_string t.class_code)
        ()
    in
    Some
      {
        placement_id;
        trade_id = t.execution_id;
        instrument;
        side = t.side;
        quantity = t.last_quantity;
        price = t.average_price;
        fee = t.commission;
        ts = t.transaction_time;
      }
